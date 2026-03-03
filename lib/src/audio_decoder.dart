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
  final bool decrypt;

  /// Encryption seed. Must match firmware `AUDIO_USB_ENCRYPT_SEED`.
  final int seed;

  const BmcAudioConfig({
    this.sampleRate = 16000,
    this.channels = 1,
    this.decrypt = true,
    this.seed = BmcAudioCrypto.defaultSeed,
  });

  @override
  String toString() =>
      'BmcAudioConfig(sampleRate: $sampleRate, channels: $channels, '
      'decrypt: $decrypt, seed: 0x${seed.toRadixString(16).toUpperCase()})';
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

  /// Offset search state (for non-Android platforms)
  bool _offsetFound = false;
  final List<Uint8List> _offsetSearchBuffer = [];
  int _offsetSearchBytes = 0;

  /// Minimum bytes to collect before running offset search (~0.5s at 16kHz mono 16-bit)
  static const int _offsetSearchMinBytes = 16000;

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
  /// On other platforms: uses flutter_recorder (miniaudio).
  Future<List<BmcAudioDevice>> listDevices({bool usbOnly = false}) async {
    if (_isAndroid) {
      return _listDevicesAndroid(usbOnly: usbOnly);
    } else {
      return _listDevicesDesktop(usbOnly: usbOnly);
    }
  }

  /// Android: list devices via native platform channel.
  /// Merges AudioManager devices + UsbManager audio-class devices
  /// (for composite USB devices that Android HAL doesn't recognize).
  Future<List<BmcAudioDevice>> _listDevicesAndroid(
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

      // 2. UsbManager devices (hardware USB — for composite devices)
      // Add USB audio-class devices NOT already in AudioManager
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

        // Check if already in AudioManager result
        if (hasUsbAudioInManager) {
          _debug('  USB device "$productName" — already in AudioManager');
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

  /// Desktop/iOS: list devices via flutter_recorder.
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

    _state = BmcCaptureState.initializing;

    _outputController = StreamController<Uint8List>.broadcast(
      onCancel: () {
        if (_outputController?.hasListener == false) {
          stopCapture();
        }
      },
    );

    if (_config.decrypt) {
      _crypto = BmcAudioCrypto(seed: _config.seed);
      _debug('Crypto enabled (seed=0x${_config.seed.toRadixString(16)})');
    }

    // Reset offset search state
    _offsetFound = _isAndroid; // Android USB Direct starts at offset 0
    _offsetSearchBuffer.clear();
    _offsetSearchBytes = 0;

    if (_isAndroid) {
      _startCaptureAndroid(deviceId: deviceId, device: device);
    } else {
      _startCaptureDesktop(deviceId ?? device?.id);
    }

    return _outputController!.stream;
  }

  /// Android: start capture — auto-selects USB direct or AudioRecord.
  Future<void> _startCaptureAndroid({
    String? deviceId,
    BmcAudioDevice? device,
  }) async {
    try {
      // Determine if this is a USB-direct device (composite, not in AudioManager)
      final bool isUsbDirect = device?.vendorId != null && device?.productId != null;

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
        // Standard AudioRecord capture
        _debug('Android: AudioRecord capture mode');

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
        _debug('✓ AudioRecord capture started');
      }
    } catch (e, stack) {
      _debug('FAILED to start Android capture: $e');
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

  /// Desktop/iOS: start capture via flutter_recorder.
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
  /// On non-Android platforms, the first chunks are buffered for offset search
  /// to find the correct keystream position (since capture starts at an
  /// unknown firmware sample position).
  void _processRawPcm(Uint8List rawPcm) {
    if (_state != BmcCaptureState.capturing) return;

    try {
      if (_config.decrypt && _crypto != null) {
        // On Android USB Direct: offset is always 0 (we read from stream start)
        // On other platforms: need offset search
        if (!_isAndroid && !_offsetFound) {
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
      if (_isAndroid) {
        await _methodChannel.invokeMethod('stopCapture');
      } else {
        try {
          Recorder.instance.stopStreamingData();
          Recorder.instance.stop();
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
  void updateConfig({bool? decrypt, int? seed}) {
    if (decrypt != null) {
      _config = BmcAudioConfig(
        sampleRate: _config.sampleRate,
        channels: _config.channels,
        decrypt: decrypt,
        seed: seed ?? _config.seed,
      );

      if (decrypt && _crypto == null) {
        _crypto = BmcAudioCrypto(seed: _config.seed);
      } else if (!decrypt) {
        _crypto = null;
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

    if (!_isAndroid && _recorderInitialized) {
      try {
        Recorder.instance.deinit();
      } catch (_) {}
      _recorderInitialized = false;
    }
  }
}
