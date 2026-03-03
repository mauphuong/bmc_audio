/// BMC Audio — Capture and decrypt audio from BMC USB Audio (UAC2.0) device.
///
/// This library provides:
/// - [BmcAudioDecoder] — Main API for capturing and decrypting audio
/// - [BmcAudioCrypto] — Pure Dart XOR-based PCM16LE encryption/decryption
/// - [BmcAudioDevice] — Audio device model with USB auto-detection
/// - [BmcAudioConfig] — Audio capture configuration
///
/// ## Quick Start
///
/// ```dart
/// import 'package:bmc_audio/bmc_audio.dart';
///
/// final decoder = BmcAudioDecoder();
///
/// // List devices and find BMC USB mic
/// final devices = await decoder.listDevices();
/// print('Available devices: $devices');
///
/// // Start capture with auto-detection
/// final stream = decoder.startCapture();
/// stream.listen((pcmData) {
///   // pcmData is decrypted PCM16LE, 16kHz, mono
///   processAudio(pcmData);
/// });
///
/// // Stop when done
/// await decoder.stopCapture();
/// decoder.dispose();
/// ```
library;

export 'src/audio_crypto.dart';
export 'src/audio_decoder.dart';
export 'src/audio_device.dart';
