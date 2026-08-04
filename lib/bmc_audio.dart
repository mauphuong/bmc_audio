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
/// stream.listen(
///   (pcmData) {
///     // pcmData is decrypted PCM16LE, 16kHz, mono
///     processAudio(pcmData);
///   },
///   // Always handle errors. The stream reports conditions the decoder cannot
///   // recover from on its own -- most importantly the device going away
///   // mid-capture, which leaves the keystream unrecoverable. Restarting the
///   // capture is what fixes it, and only the app can decide to do that.
///   onError: (Object error) async {
///     await decoder.stopCapture();
///     // ...then start again if the app still wants audio.
///   },
/// );
///
/// // Stop when done
/// await decoder.stopCapture();
/// decoder.dispose();
/// ```
///
/// ## Health
///
/// [BmcAudioDecoder.resyncCount] and [BmcAudioDecoder.droppedPackets] expose
/// how often the keystream had to be re-acquired and how many isochronous
/// packets the transport lost. Both should stay at zero on a healthy link;
/// a steadily climbing `resyncCount` means audio is being lost even though the
/// stream keeps producing samples.
library;

export 'src/audio_crypto.dart';
export 'src/audio_decoder.dart';
export 'src/audio_device.dart';
