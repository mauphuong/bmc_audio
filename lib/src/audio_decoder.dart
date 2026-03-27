import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_recorder/flutter_recorder.dart';

import 'audio_crypto.dart';
import 'audio_device.dart';

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

  /// Whether we're running on a platform with native plugin (Android or iOS).
  bool get _hasNativePlugin => _isAndroid || _isIOS;

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

        final device = BmcAudioDevice(
          id: id,
          name: displayName,
          isUsb: isUsb,
          isBmc: BmcAudioDevice.looksLikeBmc(displayName) ||
              BmcAudioDevice.looksLikeBmc(productName),
        );

        _debug('  [${device.id}] "${device.name}" usb=$isUsb');

        if (!usbOnly || device.isUsb) {
          result.add(device);
        }
      }

      // 2. UsbManager devices (Android only — for composite USB devices)
      // Add USB audio-class devices NOT already in AudioManager
      if (!_isAndroid) return result;

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
      // Determine if this is a USB-direct device (Android composite, not in AudioManager)
      final bool isUsbDirect = _isAndroid &&
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
        // CoreAudio's Float32 pipeline is lossy and breaks XOR decryption.
        // The CCID bridge reads encrypted PCM16LE bit-exact via CryptoTokenKit.
        final bool useIosCcid = !_isAndroid &&
            _resolvedDecrypt == true &&
            (device?.isBmc ?? false);

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
      (data) {
        if (data is Uint8List) {
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
          _outputController?.add(pcmData);
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
            _debug('Offset search: best=$bestOffset, score=${bestScore.toStringAsFixed(4)}');

            _offsetFound = true;
            _crypto!.reset();
            _crypto!.sampleIndex = bestOffset;

            // Process all buffered data with correct offset
            _crypto!.transformPcm16le(combined);
            _outputController?.add(combined);
            _offsetSearchBuffer.clear();
            _offsetSearchBytes = 0;
          }
          return;
        }

        _crypto!.transformPcm16le(rawPcm);
      }
      _outputController?.add(rawPcm);
    } catch (e) {
      _debug('Error processing audio: $e');
    }
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
