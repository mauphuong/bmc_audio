import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_recorder/flutter_recorder.dart';

import 'audio_crypto.dart';
import 'audio_device.dart';
import 'audio_stats.dart';

/// Audio format configuration for capture.
class BmcAudioConfig {
  /// Sample rate in Hz. Default 16000 to match BMC firmware.
  final int sampleRate;

  /// Number of audio channels. Default 1 (mono).
  final int channels;

  /// Whether to apply XOR decryption to the audio stream.
  ///
  /// - `null` (default) = **auto-detect**: decrypt if device is BMC, raw otherwise.
  /// - `true` = always decrypt.
  /// - `false` = always output raw PCM (no decryption).
  final bool? decrypt;

  /// Encryption seed. Must match firmware `AUDIO_USB_ENCRYPT_SEED`.
  final int seed;

  const BmcAudioConfig({
    this.sampleRate = 16000,
    this.channels = 1,
    this.decrypt,
    this.seed = BmcAudioCrypto.defaultSeed,
  });

  @override
  String toString() =>
      'BmcAudioConfig(sampleRate: $sampleRate, channels: $channels, '
      'decrypt: ${decrypt ?? "auto"}, seed: 0x${seed.toRadixString(16).toUpperCase()})';
}

/// Capture state of the decoder.
enum BmcCaptureState {
  /// Not capturing.
  idle,

  /// Initializing audio device.
  initializing,

  /// Actively capturing and streaming audio.
  capturing,

  /// Stopping capture.
  stopping,
}

/// BMC Audio Decoder — Main API for capturing and decrypting audio.
///
/// Uses native platform channels on Android (for USB device selection via
/// AudioManager + AudioRecord) and `flutter_recorder` (miniaudio) on
/// other platforms (Windows, Linux, iOS, macOS).
///
/// Usage:
/// ```dart
/// final decoder = BmcAudioDecoder();
///
/// // List available devices
/// final devices = await decoder.listDevices();
///
/// // Start capture with auto-detect BMC device
/// final stream = decoder.startCapture();
/// stream.listen((pcmData) {
///   // pcmData is clean (decrypted) PCM16LE audio
/// });
///
/// // Stop capture
/// await decoder.stopCapture();
/// decoder.dispose();
/// ```
class BmcAudioDecoder {
  // Platform channels (Android)
  static const MethodChannel _methodChannel = MethodChannel('bmc_audio');
  static const EventChannel _eventChannel =
      EventChannel('bmc_audio/audio_stream');

  /// Audio configuration.
  BmcAudioConfig _config;

  /// Crypto engine instance.
  BmcAudioCrypto? _crypto;

  /// Current capture state.
  BmcCaptureState _state = BmcCaptureState.idle;

  /// Stream controller for decoded audio output.
  StreamController<Uint8List>? _outputController;

  /// Subscription to audio data stream (EventChannel on Android, flutter_recorder on others).
  StreamSubscription? _audioSubscription;

  /// Whether the recorder has been initialized (non-Android only).
  bool _recorderInitialized = false;

  /// Resolved decrypt state (set in startCapture, used by _processRawPcm).
  bool _resolvedDecrypt = false;

  /// Offset search state (for non-Android platforms)
  bool _offsetFound = false;

  /// Whether capture is via CCID tunnel (iOS). When true, offset search is
  /// skipped because firmware resets sampleIndex=0 on startStream.
  bool _ccidMode = false;
  final List<Uint8List> _offsetSearchBuffer = [];
  int _offsetSearchBytes = 0;

  /// Minimum bytes to collect before running offset search (~1s at 16kHz mono 16-bit)
  static const int _offsetSearchMinBytes = 32000;

  // ── Keystream desync detection and recovery ──────────────────────────
  //
  // Isochronous transfers are not retransmitted. A single lost packet shifts
  // the host's keystream position relative to the firmware's, and because the
  // keystream is a function of a free-running sample counter every subsequent
  // sample then decrypts to noise -- permanently. The original implementation
  // locked the offset once and never revisited it, so one lost packet ended
  // the useful part of the recording.
  //
  // Recovery works in two ways: the native layer reports packets it knows were
  // dropped (immediate, certain), and the decrypted output is scored
  // continuously (catches every other cause, including losses the host
  // controller never reports).

  /// Rolling mean adjacent-sample difference of the decrypted output.
  double _healthDiff = 0.0;

  /// Whether [_healthDiff] has been seeded.
  bool _healthSeeded = false;

  /// Weight of each new chunk in the [_healthDiff] EMA.
  static const double _healthAlpha = 0.25;

  /// Above this mean adjacent difference the output is considered desynced.
  ///
  /// Uniformly random 16-bit samples average about 21800; correctly decrypted
  /// speech stays well under 6000 even when loud. The gap is wide enough that
  /// a fixed threshold discriminates reliably.
  static const double _desyncDiffThreshold = 12000.0;

  /// True while collecting fresh cipher data to re-acquire the offset.
  bool _resyncing = false;
  final List<Uint8List> _resyncBuffer = [];
  int _resyncBytes = 0;

  /// Keystream index the firmware is believed to be at when resync began.
  int _resyncExpectedIndex = 0;

  /// Bytes of cipher to collect before attempting re-acquisition (~256 ms).
  static const int _resyncMinBytes = 8192;

  /// How far either side of the expected index a narrow re-acquisition looks.
  ///
  /// Sized for the common case: a handful of lost isochronous packets shifts
  /// the alignment by tens of samples.
  static const int _resyncRadius = 512;

  /// Consecutive re-acquisition windows that failed to produce a clean lock.
  int _resyncAttempts = 0;

  /// After this many failures the stream is reported as unrecoverable.
  ///
  /// Re-acquisition still keeps running afterwards, but the listener is told
  /// once so it can decide to tear the capture down and start again — which is
  /// the only thing that helps if the device itself went away.
  static const int _maxResyncAttempts = 4;

  /// Whether the desync error has already been reported to the listener.
  bool _desyncReported = false;

  /// Number of times the keystream has been re-acquired this session.
  int _resyncCount = 0;

  /// Number of times the keystream has been re-acquired since capture started.
  int get resyncCount => _resyncCount;

  /// Packets the native layer reported as lost since capture started.
  int _droppedPackets = 0;

  /// Packets the native layer reported as lost since capture started.
  int get droppedPackets => _droppedPackets;

  // ── Delivery accounting ──────────────────────────────────────────────
  //
  // Counting what actually reaches the listener is the only measurement that
  // compares across platforms: iOS reads over the reliable CCID channel and
  // Android over isochronous, so their transports have no common unit, but
  // "how much of a second of audio did you deliver" applies to both.

  int _samplesEmitted = 0;
  DateTime? _captureStartedAt;
  Timer? _statsTimer;

  /// How often the decoder logs a health line while capturing.
  static const Duration _statsInterval = Duration(seconds: 5);

  /// Delivery statistics for the current session.
  ///
  /// Returns null before the first capture starts.
  BmcAudioStats? get stats {
    final started = _captureStartedAt;
    if (started == null) return null;
    final elapsed = DateTime.now().difference(started);
    return BmcAudioStats(
      elapsed: elapsed,
      samplesEmitted: _samplesEmitted,
      samplesExpected: elapsed.inMilliseconds * _config.sampleRate ~/ 1000,
      droppedPackets: _droppedPackets,
      resyncCount: _resyncCount,
    );
  }

  /// Hand PCM to the listener, keeping the delivery count honest.
  ///
  /// Every path that produces audio goes through here — the first locked
  /// window, ordinary chunks, and the window replayed after a re-acquisition —
  /// so the count cannot drift from what was actually emitted.
  void _emit(Uint8List pcm) {
    _samplesEmitted += pcm.length ~/ 2;
    _outputController?.add(pcm);
  }

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(_statsInterval, (_) {
      final s = stats;
      if (s != null) _debug(s.toString());
    });
  }

  /// Optional debug callback — called with status messages.
  void Function(String message)? onDebug;

  /// Whether we're running on Android.
  bool get _isAndroid {
    try {
      return !kIsWeb && Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Whether we're running on iOS.
  bool get _isIOS {
    try {
      return !kIsWeb && Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// Whether we're running on Linux desktop.
  bool get _isLinux {
    try {
      return !kIsWeb && Platform.isLinux;
    } catch (_) {
      return false;
    }
  }

  /// Whether we're running on a platform with a native plugin.
  ///
  /// Android/iOS use platform channels for bit-exact capture. Linux also uses
  /// the native plugin (libusb isochronous) so USB audio bytes are delivered
  /// bit-exact — mandatory for XOR decryption. Windows/macOS still fall back to
  /// `flutter_recorder`.
  bool get _hasNativePlugin => _isAndroid || _isIOS || _isLinux;

  /// Create a decoder with default or custom configuration.
  BmcAudioDecoder({BmcAudioConfig? config})
      : _config = config ?? const BmcAudioConfig();

  /// Current sample index position in the keystream.
  int get sampleIndex => _crypto?.sampleIndex ?? 0;

  /// Set the sample index position (used by offset search).
  set sampleIndex(int value) {
    if (_crypto != null) {
      _crypto!.sampleIndex = value;
    }
  }

  /// Current capture state.
  BmcCaptureState get state => _state;

  /// Whether the decoder is currently capturing.
  bool get isCapturing => _state == BmcCaptureState.capturing;

  /// Current configuration.
  BmcAudioConfig get config => _config;

  /// The crypto engine (available after [startCapture]).
  BmcAudioCrypto? get crypto => _crypto;

  void _debug(String msg) {
    debugPrint('BmcAudioDecoder: $msg');
    onDebug?.call(msg);
  }

  // ════════════════════════════════════════════════════════════════════
  // Device Enumeration
  // ════════════════════════════════════════════════════════════════════

  /// List available audio capture devices.
  ///
  /// On Android: uses native AudioManager.getDevices() — shows USB devices.
  /// On iOS: uses native AVAudioSession — shows USB audio ports.
  /// On other platforms: uses flutter_recorder (miniaudio).
  Future<List<BmcAudioDevice>> listDevices({bool usbOnly = false}) async {
    if (_hasNativePlugin) {
      return _listDevicesNative(usbOnly: usbOnly);
    } else {
      return _listDevicesDesktop(usbOnly: usbOnly);
    }
  }

  /// Android/iOS: list devices via native platform channel.
  /// On Android: merges AudioManager + UsbManager devices.
  /// On iOS: uses AVAudioSession.availableInputs.
  Future<List<BmcAudioDevice>> _listDevicesNative(
      {bool usbOnly = false}) async {
    try {
      final result = <BmcAudioDevice>[];

      // 1. AudioManager devices (standard audio inputs)
      final List<dynamic> audioDevices =
          await _methodChannel.invokeMethod('listDevices') ?? [];

      _debug('AudioManager: ${audioDevices.length} devices');

      for (final raw in audioDevices) {
        final map = Map<String, dynamic>.from(raw as Map);
        final id = map['id']?.toString() ?? '0';
        final name = map['name']?.toString() ?? 'Unknown';
        final typeName = map['typeName']?.toString() ?? '';
        final isUsb = map['isUsb'] as bool? ?? false;
        final productName = map['productName']?.toString() ?? '';

        final displayName = productName.isNotEmpty
            ? '$productName ($typeName)'
            : '$name ($typeName)';

        // The native side may already know this is a BMC device from a source
        // stronger than the name (iOS: IORegistry VID=0x1FC9). Never let the
        // name heuristic override that — USB product strings are not guaranteed
        // to contain "S-USB"/"AIO".
        final device = BmcAudioDevice(
          id: id,
          name: displayName,
          isUsb: isUsb,
          isBmc: (map['isBmc'] as bool? ?? false) ||
              BmcAudioDevice.looksLikeBmc(displayName) ||
              BmcAudioDevice.looksLikeBmc(productName),
          vendorId: map['vendorId'] as int?,
          productId: map['productId'] as int?,
        );

        _debug('  [${device.id}] "${device.name}" usb=$isUsb');

        if (!usbOnly || device.isUsb) {
          result.add(device);
        }
      }

      // 2. USB hardware devices (Android + Linux — for composite USB devices).
      // Add USB audio-class devices NOT already in the OS device list, and
      // enrich existing entries with VID/PID so the USB-direct capture path
      // (isochronous) can be used.
      if (!_isAndroid && !_isLinux) return result;

      final bool hasUsbAudioInManager = result.any((d) => d.isUsb);

      final List<dynamic> usbDevices =
          await _methodChannel.invokeMethod('listUsbDevices') ?? [];

      for (final raw in usbDevices) {
        final map = Map<String, dynamic>.from(raw as Map);
        final isAudio = map['isAudioClass'] as bool? ?? false;
        if (!isAudio) continue;

        final vid = map['vendorId'] as int? ?? 0;
        final pid = map['productId'] as int? ?? 0;
        final productName = map['productName']?.toString() ?? 'USB Audio';
        final mfrName = map['manufacturerName']?.toString() ?? '';

        // If already in AudioManager, enrich existing entry with VID/PID
        // so USB Direct capture path can be used (AudioRecord is unreliable
        // for encrypted USB audio on some devices like Android 14 Samsung).
        if (hasUsbAudioInManager) {
          final existing = result.firstWhere((d) => d.isUsb, orElse: () => result.first);
          if (existing.vendorId == null) {
            final idx = result.indexOf(existing);
            result[idx] = BmcAudioDevice(
              id: existing.id,
              name: existing.name,
              isUsb: existing.isUsb,
              isBmc: existing.isBmc || BmcAudioDevice.looksLikeBmc(productName),
              vendorId: vid,
              productId: pid,
            );
            _debug('  USB device "$productName" — enriched with VID=0x${vid.toRadixString(16)} PID=0x${pid.toRadixString(16)}');
          } else {
            _debug('  USB device "$productName" — already in AudioManager');
          }
          continue;
        }

        // Add as USB-direct device (uses VID/PID for startUsbCapture)
        final displayName = mfrName.isNotEmpty
            ? '$productName ($mfrName) [USB Direct]'
            : '$productName [USB Direct]';

        final device = BmcAudioDevice(
          id: 'usb:${vid.toRadixString(16)}:${pid.toRadixString(16)}',
          name: displayName,
          isUsb: true,
          isBmc: BmcAudioDevice.looksLikeBmc(productName) ||
              BmcAudioDevice.looksLikeBmc(mfrName),
          vendorId: vid,
          productId: pid,
        );

        _debug('  [USB-Direct] "$displayName" vid=0x${vid.toRadixString(16)} '
            'pid=0x${pid.toRadixString(16)}');

        result.add(device);
      }

      return result;
    } catch (e) {
      _debug('Error listing Android devices: $e');
      return [];
    }
  }


  /// Desktop: list devices via flutter_recorder.
  Future<List<BmcAudioDevice>> _listDevicesDesktop(
      {bool usbOnly = false}) async {
    try {
      if (!_recorderInitialized) {
        _debug('Initializing recorder for device listing...');
        try {
          await Recorder.instance.init();
          _recorderInitialized = true;
          _debug('Recorder initialized OK');
        } catch (e) {
          _debug('Recorder init error: $e');
          // Try listing anyway — some implementations don't need init
        }
      }

      final devices = Recorder.instance.listCaptureDevices();
      _debug('Desktop: Found ${devices.length} capture devices:');

      final result = <BmcAudioDevice>[];
      for (final device in devices) {
        final bmcDevice = BmcAudioDevice.fromRecorderDevice(
          id: device.id.toString(),
          name: device.name,
        );
        _debug('  [${device.id}] "${device.name}" '
            'usb=${bmcDevice.isUsb} bmc=${bmcDevice.isBmc}');

        if (!usbOnly || bmcDevice.isUsb) {
          result.add(bmcDevice);
        }
      }

      return result;
    } catch (e) {
      _debug('Error listing desktop devices: $e');
      return [];
    }
  }

  /// Auto-detect a BMC USB device from available capture devices.
  ///
  /// Returns a BMC device if found, otherwise a USB device, otherwise `null`.
  /// For a method that also falls back to the default mic, use [findBestDevice].
  Future<BmcAudioDevice?> findBmcDevice() async {
    final devices = await listDevices();
    for (final device in devices) {
      if (device.isBmc) return device;
    }
    for (final device in devices) {
      if (device.isUsb) return device;
    }
    return null;
  }

  /// Find the best available audio device with priority: BMC > USB > default mic.
  ///
  /// Unlike [findBmcDevice], this always returns a device if any are available.
  /// Combined with auto-decrypt (`BmcAudioConfig(decrypt: null)`), this provides
  /// a zero-config experience:
  /// - BMC device → automatically decrypted audio
  /// - Non-BMC device → raw audio
  ///
  /// ```dart
  /// final device = await decoder.findBestDevice();
  /// if (device != null) {
  ///   final stream = decoder.startCapture(device: device);
  ///   // Audio is automatically decrypted if BMC, raw if default mic
  /// }
  /// ```
  Future<BmcAudioDevice?> findBestDevice() async {
    final devices = await listDevices();
    return devices.where((d) => d.isBmc).firstOrNull ??
        devices.where((d) => d.isUsb).firstOrNull ??
        devices.firstOrNull;
  }

  // ════════════════════════════════════════════════════════════════════
  // Capture
  // ════════════════════════════════════════════════════════════════════

  /// Start capturing audio from the specified device.
  ///
  /// Pass [device] (from [listDevices]) to select a specific device.
  /// On Android, if the device has [vendorId]/[productId] set (USB Direct),
  /// it will use direct USB isochronous capture.
  ///
  /// Returns a [Stream<Uint8List>] of PCM16LE audio data.
  Stream<Uint8List> startCapture({
    String? deviceId,
    BmcAudioDevice? device,
    BmcAudioConfig? config,
  }) {
    if (_state != BmcCaptureState.idle) {
      throw StateError(
          'Cannot start capture: current state is $_state. '
          'Call stopCapture() first.');
    }

    if (config != null) {
      _config = config;
    }

    // Resolve auto-decrypt: null → based on device type
    final bool shouldDecrypt;
    if (_config.decrypt != null) {
      shouldDecrypt = _config.decrypt!;
      _debug('Decrypt: ${shouldDecrypt ? "ON" : "OFF"} (explicit)');
    } else {
      // Auto-detect: decrypt if BMC device, raw otherwise
      shouldDecrypt = device?.isBmc ?? false;
      _debug('Auto-decrypt: ${shouldDecrypt ? "ON (BMC device)" : "OFF (non-BMC device)"}');
    }

    _state = BmcCaptureState.initializing;

    _outputController = StreamController<Uint8List>.broadcast(
      onCancel: () {
        if (_outputController?.hasListener == false) {
          stopCapture();
        }
      },
    );

    if (shouldDecrypt) {
      _crypto = BmcAudioCrypto(seed: _config.seed);
      _debug('Crypto enabled (seed=0x${_config.seed.toRadixString(16)})');
    } else {
      _crypto = null;
      _debug('Crypto disabled — outputting raw PCM');
    }

    // Store resolved decrypt state for _processRawPcm
    _resolvedDecrypt = shouldDecrypt;

    // Reset offset search state.
    _offsetFound = false;
    _ccidMode = false;
    _offsetSearchBuffer.clear();
    _offsetSearchBytes = 0;

    // Reset desync detection / recovery state.
    _resyncing = false;
    _resyncBuffer.clear();
    _resyncBytes = 0;
    _resyncCount = 0;
    _resyncAttempts = 0;
    _desyncReported = false;
    _droppedPackets = 0;
    _resetHealth();

    // Delivery accounting for this session.
    _samplesEmitted = 0;
    _captureStartedAt = DateTime.now();
    _startStatsTimer();

    if (_hasNativePlugin) {
      _startCaptureNative(deviceId: deviceId, device: device);
    } else {
      _startCaptureDesktop(deviceId ?? device?.id);
    }

    return _outputController!.stream;
  }

  /// Android/iOS: start capture via native MethodChannel.
  /// On Android: auto-selects USB direct or AudioRecord.
  /// On iOS: uses AVAudioEngine via native plugin.
  Future<void> _startCaptureNative({
    String? deviceId,
    BmcAudioDevice? device,
  }) async {
    try {
      // Determine if this is a USB-direct device (Android/Linux composite).
      final bool isUsbDirect = (_isAndroid || _isLinux) &&
          device?.vendorId != null && device?.productId != null;

      if (isUsbDirect) {
        _debug('Android: USB Direct capture mode');
        _debug('  VID=0x${device!.vendorId!.toRadixString(16)} '
            'PID=0x${device.productId!.toRadixString(16)}');

        // Ensure USB permission
        try {
          final permResult =
              await _methodChannel.invokeMethod('requestUsbPermission', {
            'vendorId': device.vendorId,
            'productId': device.productId,
          });
          final granted =
              (permResult as Map?)?['granted'] as bool? ?? false;
          if (!granted) {
            throw Exception('USB permission denied');
          }
          _debug('USB permission: ✓');
        } catch (e) {
          _debug('USB permission error: $e');
          rethrow;
        }

        // Listen to EventChannel for audio data
        _setupEventChannelListener();

        // Start USB direct capture
        final captureResult =
            await _methodChannel.invokeMethod('startUsbCapture', {
          'vendorId': device.vendorId,
          'productId': device.productId,
          'sampleRate': _config.sampleRate,
          'channels': _config.channels,
        });

        _state = BmcCaptureState.capturing;
        _debug('✓ USB Direct capture started');
        if (captureResult is Map) {
          _debug('  endpoint=0x${(captureResult['endpoint'] as int?)?.toRadixString(16) ?? "?"}');
          _debug('  maxPacketSize=${captureResult['maxPacketSize']}');
        }
      } else {
        // Standard capture (AudioRecord on Android, AVAudioEngine on iOS)

        // iOS + BMC device + decrypt ON → use CCID audio bridge
        // CoreAudio's Float32 pipeline resamples audio → breaks XOR decryption.
        // The CCID bridge reads encrypted PCM16LE bit-exact via CryptoTokenKit.
        _debug('Capture path decision: isAndroid=$_isAndroid, '
            'decrypt=$_resolvedDecrypt, '
            'device.isBmc=${device?.isBmc}, '
            'device.name="${device?.name}", '
            'device.isUsb=${device?.isUsb}');

        // CCID is the ONLY bit-exact capture path on iOS, so decryption implies
        // it. Gating on `device.isBmc` here used to mean that a device lookup
        // failing — which it does while the app is backgrounded and CallKit owns
        // the audio session, so AVAudioSession exposes no inputs — silently
        // downgraded to AVAudioEngine while decryption stayed ON. That combination
        // XORs a resampled Float32 stream and transmits white noise, with no
        // error anywhere: capture starts, chunks flow, the call proceeds.
        // Failing to open CCID is loud (see the throw below); guessing is not.
        final bool useIosCcid = _isIOS && _resolvedDecrypt == true;

        _debug('→ useIosCcid=$useIosCcid');

        if (useIosCcid) {
          _debug('iOS: CCID audio bridge mode (bit-exact encrypted PCM)');
          _setupEventChannelListener();

          // CCID mode: firmware resets sampleIndex=0 on startStream,
          // so offset is always 0. Skip offset search (which fails
          // during mic warmup silence).
          _ccidMode = true;
          _offsetFound = true;
          _crypto!.reset();
          _crypto!.sampleIndex = 0;
          _debug('CCID mode: offset fixed at 0 (firmware crypto reset)');

          final result = await _methodChannel.invokeMethod('startCcidCapture');

          _state = BmcCaptureState.capturing;
          _debug('✓ CCID capture started: $result');
        } else {
          // Structurally unreachable on iOS (useIosCcid covers every decrypting
          // case). Kept as a tripwire: emitting XOR-ed CoreAudio output is worse
          // than no audio at all, because it sounds like a hardware fault and
          // costs days to trace back to a capture-path decision.
          if (_isIOS && _resolvedDecrypt) {
            throw StateError(
              'decrypt=ON but CCID path not selected — refusing lossy capture '
              '(device=${device?.name}, isBmc=${device?.isBmc})',
            );
          }
          if (_resolvedDecrypt) {
            _debug('⚠️ decrypt=ON over the platform capture path — this is only '
                'bit-exact when the OS does not resample (Android USB Direct is '
                'the reliable path); output may be noise.');
          }

          _debug('${_isAndroid ? "Android" : "iOS"}: Native capture mode');

          final int? parsedDeviceId = deviceId != null
              ? int.tryParse(deviceId)
              : (device?.id != null ? int.tryParse(device!.id) : null);

          _setupEventChannelListener();

          await _methodChannel.invokeMethod('startCapture', {
            'deviceId': parsedDeviceId,
            'sampleRate': _config.sampleRate,
            'channels': _config.channels,
          });

          _state = BmcCaptureState.capturing;
          _debug('✓ Native capture started');
        }
      }
    } catch (e, stack) {
      _debug('FAILED to start native capture: $e');
      _debug('Stack: ${stack.toString().split('\n').take(3).join(' | ')}');
      _state = BmcCaptureState.idle;
      _outputController?.addError(e);
      _outputController?.close();
    }
  }

  /// Set up the EventChannel listener for audio data (shared by both capture modes).
  void _setupEventChannelListener() {
    int chunkCount = 0;
    _audioSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        // Two payload shapes are accepted. Platforms that can account for lost
        // isochronous packets send {'pcm': Uint8List, 'dropped': int}; the
        // others (and older native builds) send the bytes directly.
        Uint8List? data;
        int dropped = 0;

        if (event is Uint8List) {
          data = event;
        } else if (event is Map) {
          final pcm = event['pcm'];
          if (pcm is Uint8List) data = pcm;
          final d = event['dropped'];
          if (d is int) dropped = d;
        }

        if (dropped > 0) {
          _onPacketsDropped(dropped);
        }
        if (data != null) {
          chunkCount++;
          if (chunkCount <= 3 || chunkCount % 100 == 0) {
            _debug('Audio chunk #$chunkCount: ${data.length} bytes');
          }
          _processRawPcm(data);
        }
      },
      onError: (error) {
        _debug('EventChannel error: $error');
        _outputController?.addError(error);
      },
      onDone: () {
        _debug('EventChannel done');
      },
    );
  }


  /// Desktop: start capture via flutter_recorder.
  Future<void> _startCaptureDesktop(String? deviceId) async {
    try {
      if (_recorderInitialized) {
        _debug('Deinit previous recorder...');
        try {
          Recorder.instance.deinit();
        } catch (_) {}
        _recorderInitialized = false;
      }

      final int? parsedDeviceId =
          deviceId != null ? int.tryParse(deviceId) : null;

      _debug('Init recorder: sampleRate=${_config.sampleRate}, '
          'format=s16le, channels=${_config.channels}, '
          'deviceID=${parsedDeviceId ?? "default"}');

      await Recorder.instance.init(
        deviceID: parsedDeviceId ?? -1,
        sampleRate: _config.sampleRate,
        channels: _config.channels == 1
            ? RecorderChannels.mono
            : RecorderChannels.stereo,
        format: PCMFormat.s16le,
      );
      _recorderInitialized = true;
      _debug('Recorder initialized OK');

      int chunkCount = 0;
      _audioSubscription = Recorder.instance.uint8ListStream.listen(
        (data) {
          chunkCount++;
          final rawData = Uint8List.fromList(data.rawData);
          if (chunkCount <= 5 || chunkCount % 100 == 0) {
            // Diagnostic: compute min/max/RMS of raw int16 samples
            int minVal = 32767, maxVal = -32768;
            double sumSq = 0;
            final sampleCount = rawData.length ~/ 2;
            for (int i = 0; i < sampleCount; i++) {
              int s = rawData[i * 2] | (rawData[i * 2 + 1] << 8);
              if (s > 32767) s -= 65536;
              if (s < minVal) minVal = s;
              if (s > maxVal) maxVal = s;
              sumSq += s * s;
            }
            final rms = sampleCount > 0 ? (sumSq / sampleCount) : 0.0;
            _debug('Chunk #$chunkCount: ${rawData.length}B, '
                'min=$minVal max=$maxVal rms=${rms.toStringAsFixed(0)}');
          }
          _processRawPcm(rawData);
        },
        onError: (error) {
          _debug('Stream error: $error');
          _outputController?.addError(error);
        },
        onDone: () {
          _debug('Stream done');
          stopCapture();
        },
      );

      _debug('Starting recorder...');
      Recorder.instance.start();
      _debug('Starting data streaming...');
      Recorder.instance.startStreamingData();

      _state = BmcCaptureState.capturing;
      _debug('✓ Desktop capture started');
    } catch (e, stack) {
      _debug('FAILED to start desktop capture: $e');
      _debug('Stack: ${stack.toString().split('\n').take(3).join(' | ')}');
      _state = BmcCaptureState.idle;
      _outputController?.addError(e);
      _outputController?.close();
    }
  }

  /// Process raw PCM16LE data: decrypt if enabled, forward to output stream.
  ///
  /// The first ~0.5s of audio is buffered for offset search to find the
  /// correct keystream position. This is needed on all platforms because
  /// the firmware may have sent samples before the app starts reading
  /// (e.g. priming packets, HAL buffering, etc.).
  void _processRawPcm(Uint8List rawPcm) {
    if (_state != BmcCaptureState.capturing) return;

    try {
      if (_resolvedDecrypt && _crypto != null) {
        if (_ccidMode) {
          // ── CCID mode: self-synchronizing decrypt ──
          // Each chunk = [4-byte sampleIdx LE] + [PCM16LE data]
          // Parse the sampleIndex header and set crypto before decrypting.
          if (rawPcm.length <= 4) {
            return; // Header only, no PCM data
          }
          final sampleIdx = rawPcm[0] |
              (rawPcm[1] << 8) |
              (rawPcm[2] << 16) |
              (rawPcm[3] << 24);
          final pcmData = Uint8List.sublistView(rawPcm, 4);

          _crypto!.sampleIndex = sampleIdx;
          _crypto!.transformPcm16le(pcmData);
          _emit(pcmData);
          return;
        }

        if (!_offsetFound) {
          // Buffer data for offset search
          _offsetSearchBuffer.add(Uint8List.fromList(rawPcm));
          _offsetSearchBytes += rawPcm.length;

          if (_offsetSearchBytes >= _offsetSearchMinBytes) {
            // Run offset search on collected data
            final combined = Uint8List(_offsetSearchBytes);
            int pos = 0;
            for (final chunk in _offsetSearchBuffer) {
              combined.setAll(pos, chunk);
              pos += chunk.length;
            }

            _debug('Running offset search on $_offsetSearchBytes bytes...');

            // ── Diagnostic: dump first bytes and check crypto alignment ──
            if (combined.length >= 16) {
              final hexDump = combined.sublist(0, 16)
                  .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
                  .join(' ');
              _debug('First 16 bytes (encrypted): $hexDump');

              // Compute expected keystream at offset 0
              final testCrypto = BmcAudioCrypto(seed: _config.seed);
              testCrypto.sampleIndex = 0;
              final testBuf = Uint8List.fromList(combined.sublist(0, 16));
              testCrypto.transformPcm16le(testBuf);
              final decHex = testBuf
                  .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
                  .join(' ');
              _debug('After XOR offset=0: $decHex');

              // Parse first 4 decrypted samples
              final samples = <int>[];
              for (int i = 0; i < 8 && i * 2 + 1 < testBuf.length; i++) {
                int s = testBuf[i * 2] | (testBuf[i * 2 + 1] << 8);
                if (s > 32767) s -= 65536;
                samples.add(s);
              }
              _debug('Decrypted samples @offset=0: $samples');
            }

            final (bestOffset, bestScore) = BmcAudioCrypto.searchOffset(
              combined,
              seed: _config.seed,
              maxOffset: _config.sampleRate, // search up to 1 second
            );
            _debug('Offset search: best=$bestOffset, corr=${bestScore.toStringAsFixed(4)}');

            // Lock once. searchOffset uses a silence-robust metric
            // (meanAdjacentDiff), so the packet-aligned offset is correct even
            // if capture starts during silence; the keystream then stays
            // aligned as sampleIndex advances and real audio arrives.
            _offsetFound = true;
            _crypto!.reset();
            _crypto!.sampleIndex = bestOffset;
            _crypto!.transformPcm16le(combined);
            _emit(combined);
            _debug('✓ Offset LOCKED at $bestOffset');
            _offsetSearchBuffer.clear();
            _offsetSearchBytes = 0;
            _resetHealth();
          }
          return;
        }

        if (_resyncing) {
          _collectForResync(rawPcm);
          return;
        }

        _crypto!.transformPcm16le(rawPcm);
        _checkHealth(rawPcm);
      }
      _emit(rawPcm);
    } catch (e) {
      _debug('Error processing audio: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════
  // Keystream desync detection and recovery
  // ════════════════════════════════════════════════════════════════════

  /// Clear the health estimate after a (re-)lock.
  void _resetHealth() {
    _healthDiff = 0.0;
    _healthSeeded = false;
  }

  /// Score a freshly decrypted chunk and start a resync if it looks like noise.
  void _checkHealth(Uint8List plainPcm) {
    if (plainPcm.length < 4) return;

    final diff = BmcAudioCrypto.meanAdjacentDiff(plainPcm);

    if (!_healthSeeded) {
      _healthDiff = diff;
      _healthSeeded = true;
    } else {
      _healthDiff = _healthDiff * (1 - _healthAlpha) + diff * _healthAlpha;
    }

    if (_healthDiff > _desyncDiffThreshold) {
      _debug('Keystream desync detected '
          '(adjacent diff ${_healthDiff.toStringAsFixed(0)}) — re-acquiring');
      _beginResync();
    }
  }

  /// Called by the native layer when it knows isochronous packets were lost.
  ///
  /// A reported loss is certain evidence of desync, so this short-circuits the
  /// score-based detector rather than waiting for the EMA to climb.
  void _onPacketsDropped(int count) {
    if (count <= 0) return;
    _droppedPackets += count;

    if (!_resolvedDecrypt || _ccidMode || !_offsetFound || _resyncing) {
      return;
    }

    _debug('Native reported $count dropped packet(s) — re-acquiring keystream');
    _beginResync();
  }

  /// Enter the resync state: buffer cipher instead of emitting it.
  void _beginResync() {
    if (_resyncing || _crypto == null) return;
    _resyncing = true;
    _resyncBuffer.clear();
    _resyncBytes = 0;
    _resyncExpectedIndex = _crypto!.sampleIndex;
  }

  /// Accumulate cipher until there is enough of it to re-acquire the offset.
  void _collectForResync(Uint8List rawPcm) {
    _resyncBuffer.add(Uint8List.fromList(rawPcm));
    _resyncBytes += rawPcm.length;
    if (_resyncBytes < _resyncMinBytes) return;

    final combined = Uint8List(_resyncBytes);
    int pos = 0;
    for (final chunk in _resyncBuffer) {
      combined.setAll(pos, chunk);
      pos += chunk.length;
    }
    _resyncBuffer.clear();
    _resyncBytes = 0;
    final found = _tryReacquire(combined);

    if (found == null) {
      // Nothing in this window locked. Throw it away and try again on the next
      // one rather than emitting noise, which is exactly what the caller is
      // trying to get rid of.
      _resyncAttempts++;
      _debug('Re-acquisition failed (attempt $_resyncAttempts)');

      if (_resyncAttempts >= _maxResyncAttempts && !_desyncReported) {
        _desyncReported = true;
        _debug('Keystream unrecoverable after $_resyncAttempts attempts');
        _outputController?.addError(
          StateError('bmc_audio: keystream could not be re-acquired after '
              '$_resyncAttempts attempts. If the device was disconnected, '
              'call stopCapture() then startCapture() to resynchronise.'),
        );
      }
      return;
    }

    final (best, score) = found;

    _resyncing = false;
    _resyncAttempts = 0;
    _desyncReported = false;
    _resyncCount++;
    _crypto!.sampleIndex = best + (combined.length ~/ 2);
    _resetHealth();

    _debug('✓ Keystream RE-ACQUIRED at $best '
        '(was $_resyncExpectedIndex, drift ${best - _resyncExpectedIndex}, '
        'corr ${score.toStringAsFixed(3)}, resync #$_resyncCount)');

    _emit(
      BmcAudioCrypto.transform(combined, seed: _config.seed, startIndex: best),
    );
  }

  /// Try progressively wider strategies to find where the keystream really is.
  ///
  /// Returns `(offset, confidence)`, or null if none of them produced output
  /// that looks like audio rather than noise.
  (int, double)? _tryReacquire(Uint8List cipher) {
    final expected = _resyncExpectedIndex;

    // 1. A few lost packets: the alignment moved by tens of samples.
    // 2. A longer stall (host scheduling gap, hub glitch): up to a second of
    //    audio went missing.
    //
    // Both have to search *around the current index*. An absolute search would
    // be looking in the wrong place entirely: after ten minutes of streaming
    // the true index is in the millions, nowhere near 0..sampleRate.
    for (final radius in [_resyncRadius, _config.sampleRate]) {
      final (offset, score) = BmcAudioCrypto.searchOffsetNear(
        cipher,
        center: expected,
        seed: _config.seed,
        radius: radius,
      );
      if (_locksCleanly(cipher, offset)) {
        _debug('Re-acquired within radius $radius');
        return (offset, score);
      }
    }

    // 3. The device re-primed its stream. Firmware calls AudioCrypto_Reset()
    //    from UAC2_AppPrimeStream(), so after a re-enumeration or an
    //    alt-setting bounce its keystream restarts near zero no matter how
    //    long the previous session ran.
    final (offset, score) = BmcAudioCrypto.searchOffset(
      cipher,
      seed: _config.seed,
      maxOffset: _config.sampleRate,
    );
    if (_locksCleanly(cipher, offset)) {
      _debug('Re-acquired near zero — the device restarted its stream');
      return (offset, score);
    }

    return null;
  }

  /// Whether decrypting [cipher] from [offset] yields audio rather than noise.
  bool _locksCleanly(Uint8List cipher, int offset) {
    final probe = BmcAudioCrypto.transform(
      cipher,
      seed: _config.seed,
      startIndex: offset,
    );
    return BmcAudioCrypto.meanAdjacentDiff(probe) <= _desyncDiffThreshold;
  }

  // ════════════════════════════════════════════════════════════════════
  // Stop / Dispose
  // ════════════════════════════════════════════════════════════════════

  /// Stop capturing audio.
  Future<void> stopCapture() async {
    if (_state == BmcCaptureState.idle || _state == BmcCaptureState.stopping) {
      return;
    }

    _state = BmcCaptureState.stopping;

    // Report the session's delivery before tearing it down: this is the line
    // that says how much audio actually made it through.
    _statsTimer?.cancel();
    _statsTimer = null;
    final finalStats = stats;
    if (finalStats != null) _debug('session ended — $finalStats');

    try {
      if (_hasNativePlugin) {
        // Android and iOS: stop via native plugin
        await _methodChannel.invokeMethod('stopCapture');
      } else {
        // Desktop: stop flutter_recorder
        try {
          Recorder.instance.stopStreamingData();
          Recorder.instance.stop();
          Recorder.instance.deinit();
          _recorderInitialized = false;
        } catch (_) {}
      }

      await _audioSubscription?.cancel();
      _audioSubscription = null;

      await _outputController?.close();
      _outputController = null;

      _crypto?.reset();

      _debug('Capture stopped');
    } catch (e) {
      _debug('Error stopping capture: $e');
    } finally {
      _state = BmcCaptureState.idle;
    }
  }

  /// Update configuration while capturing.
  ///
  /// Pass [decrypt] to explicitly enable/disable decryption mid-capture.
  /// This overrides auto-detect mode.
  void updateConfig({bool? decrypt, int? seed}) {
    if (decrypt != null) {
      _config = BmcAudioConfig(
        sampleRate: _config.sampleRate,
        channels: _config.channels,
        decrypt: decrypt,
        seed: seed ?? _config.seed,
      );

      _resolvedDecrypt = decrypt;
      if (decrypt && _crypto == null) {
        _crypto = BmcAudioCrypto(seed: _config.seed);
        _debug('Crypto enabled (manual override)');
      } else if (!decrypt) {
        _crypto = null;
        _debug('Crypto disabled (manual override)');
      }
    }

    if (seed != null && _crypto != null) {
      _crypto = BmcAudioCrypto(seed: seed);
    }
  }

  /// Release all resources.
  void dispose() {
    _statsTimer?.cancel();
    _statsTimer = null;

    if (_state != BmcCaptureState.idle) {
      stopCapture();
    }

    if (!_hasNativePlugin && _recorderInitialized) {
      try {
        Recorder.instance.deinit();
      } catch (_) {}
      _recorderInitialized = false;
    }
  }
}
