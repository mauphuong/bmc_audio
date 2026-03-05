# BMC Audio

Flutter plugin to capture and decrypt audio from **BMC USB Audio (UAC2.0)** composite devices.

- 🎤 USB Audio Capture from BMC devices (VID=0x1FC9)
- 🔓 Auto XOR decryption — BMC device → decrypted, default mic → raw
- 📱 Cross-platform — Android, iOS, Windows, Linux, macOS
- 🔌 Android composite USB — native isochronous transfer via JNI

## Quick Start

```yaml
# pubspec.yaml
dependencies:
  bmc_audio:
    path: ../path/to/bmc_audio
```

```dart
import 'package:bmc_audio/bmc_audio.dart';

final decoder = BmcAudioDecoder();

// Auto-select best device (BMC > USB > default mic)
final device = await decoder.findBestDevice();

// Start capture — auto decrypts if BMC, raw if default mic
final stream = decoder.startCapture(device: device);

stream.listen((pcmData) {
  // pcmData = PCM16LE, 16kHz, mono
  // Already decrypted if BMC device, raw otherwise
});

// Stop
await decoder.stopCapture();
decoder.dispose();
```

> **That's it!** No config needed. Decryption is automatic based on device type.

## Override Decrypt

```dart
// Force decrypt ON (any device)
decoder.startCapture(device: device, config: BmcAudioConfig(decrypt: true));

// Force raw output (no decrypt)
decoder.startCapture(device: device, config: BmcAudioConfig(decrypt: false));

// Custom seed
decoder.startCapture(device: device, config: BmcAudioConfig(seed: 0xDEADBEEF));
```

## Platform Setup

### Android

Add to `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-feature android:name="android.hardware.usb.host" android:required="false" />
```

**USB auto-permission (recommended):** Create `android/app/src/main/res/xml/device_filter.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <usb-device vendor-id="8137" product-id="279" />
</resources>
```

Add to your `<activity>`:
```xml
<intent-filter>
    <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
</intent-filter>
<meta-data
    android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
    android:resource="@xml/device_filter" />
```

### iOS

Add to `Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to capture audio from USB devices.</string>
```

### Windows / Linux / macOS

No setup required.

## API Reference

### BmcAudioDecoder

| Method | Description |
|---|---|
| `findBestDevice()` | Auto-select: BMC > USB > default mic |
| `findBmcDevice()` | Find BMC/USB device only (returns null if none) |
| `listDevices()` | List all audio capture devices |
| `startCapture({device, config})` | Start capture → `Stream<Uint8List>` |
| `stopCapture()` | Stop capture |
| `updateConfig({decrypt, seed})` | Change decrypt on/off mid-capture |
| `dispose()` | Release resources |

### BmcAudioConfig

| Parameter | Type | Default | Description |
|---|---|---|---|
| `decrypt` | `bool?` | `null` (auto) | `null`=auto, `true`=always decrypt, `false`=always raw |
| `sampleRate` | `int` | `16000` | Sample rate in Hz |
| `channels` | `int` | `1` | 1=mono, 2=stereo |
| `seed` | `int` | `0xC0FFEE12` | XOR encryption seed (must match firmware) |

### BmcAudioDevice

| Property | Type | Description |
|---|---|---|
| `id` | `String` | Platform device ID |
| `name` | `String` | Display name |
| `isUsb` | `bool` | Is USB audio device |
| `isBmc` | `bool` | Is BMC device |

### BmcAudioCrypto

Standalone crypto engine (can be used independently):

```dart
final crypto = BmcAudioCrypto(seed: 0xC0FFEE12);
crypto.transformPcm16le(encryptedBuffer);  // decrypt in-place

// One-shot (creates copy)
final decrypted = BmcAudioCrypto.transform(encrypted, seed: 0xC0FFEE12);
```

## Example App

See `example/` for a full demo with device selection, waveform, WAV save & playback.

```bash
cd example
flutter run -d windows   # or android, ios, linux, macos
```

## License

Proprietary — BMC Technology Vietnam
