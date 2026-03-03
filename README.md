# BMC Audio

Flutter plugin to capture and decrypt audio from **BMC USB Audio (UAC2.0)** composite devices with XOR-based encryption.

## Features

- 🎤 **USB Audio Capture** — from BMC composite USB devices (VID=0x1FC9)
- 🔓 **XOR Decryption** — real-time decryption of encrypted PCM16LE audio
- 📱 **Cross-platform** — Android, iOS, Windows, Linux, macOS
- 🔌 **Android Composite USB** — native isochronous transfer via JNI (no libusb needed)
- 🎯 **Auto-detection** — automatically finds and selects BMC USB devices

## Quick Start

```dart
import 'package:bmc_audio/bmc_audio.dart';

final decoder = BmcAudioDecoder();

// 1. List devices and find BMC USB mic
final devices = await decoder.listDevices();
final bmcDevice = devices.where((d) => d.isBmc).firstOrNull;

// 2. Start capture with XOR decryption
final stream = decoder.startCapture(
  device: bmcDevice,
  config: BmcAudioConfig(
    sampleRate: 16000,
    channels: 1,
    decrypt: true,
  ),
);

// 3. Process decrypted PCM16LE audio
stream.listen((pcmData) {
  // pcmData is clean (decrypted) PCM16LE, 16kHz, mono
  processAudio(pcmData);
});

// 4. Stop when done
await decoder.stopCapture();
decoder.dispose();
```

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  bmc_audio:
    path: ../path/to/bmc_audio
```

## Platform Setup

### Android

Android requires additional setup for composite USB devices:

#### 1. Microphone Permission

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-feature android:name="android.hardware.usb.host" android:required="false" />
```

#### 2. USB Auto-Permission (recommended)

To auto-grant USB permission when the BMC device is plugged in:

Create `android/app/src/main/res/xml/device_filter.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <usb-device vendor-id="8137" product-id="279" />
    <!-- vendor-id = 0x1FC9, product-id = 0x0117 -->
</resources>
```

Add to your `<activity>` in `AndroidManifest.xml`:

```xml
<intent-filter>
    <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
</intent-filter>
<meta-data
    android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
    android:resource="@xml/device_filter" />
```

> **Note:** The first time the user plugs in the device, Android will show a popup with "Always open this app" checkbox. Once checked, USB permission is granted automatically.

### Windows

Uses `flutter_recorder` (miniaudio) for audio capture through the Windows audio driver.

#### Build & Run

```bash
cd example
flutter run -d windows
```

#### Offset Search (Auto)

On Windows, the firmware has been streaming before the app starts capturing, so the XOR keystream position is unknown. The plugin **automatically searches** for the correct offset during the first ~0.5s of capture (ported from the Python `uac_capture_decrypt.py` reference tool).

Debug log will show:
```
Offset search: best=NNN, score=0.XXXX
```
A score > 0.3 indicates successful alignment.

#### Known Limitation

Windows audio driver receives encrypted PCM from the BMC USB device. Depending on the driver mode (shared vs exclusive), Windows may resample or process the data, which can affect decryption quality. For best results, ensure the BMC device is the only active audio input.

### iOS

Uses `flutter_recorder` (miniaudio) for audio capture via CoreAudio.

#### 1. Microphone Permission

Add to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to capture audio from USB devices.</string>
```

#### 2. Build & Run

```bash
cd example
flutter run -d ios
# Or open in Xcode:
open ios/Runner.xcworkspace
```

> **Note:** iOS supports USB audio devices (UAC) through the Lightning/USB-C Camera Adapter. The BMC device appears as a standard audio input.

### Linux / macOS

No special setup required. The plugin uses `flutter_recorder` (miniaudio) on these platforms.

## API Reference

### BmcAudioDecoder

Main class for capturing and decrypting audio.

| Method | Description |
|---|---|
| `listDevices({bool usbOnly})` | List available audio capture devices |
| `findBmcDevice()` | Auto-detect BMC USB device |
| `startCapture({device, deviceId, config})` | Start capturing → returns `Stream<Uint8List>` |
| `stopCapture()` | Stop capturing |
| `updateConfig({decrypt, seed})` | Update config while capturing |
| `dispose()` | Release resources |

**Properties:**

| Property | Type | Description |
|---|---|---|
| `state` | `BmcCaptureState` | Current capture state |
| `crypto` | `BmcAudioCrypto?` | Crypto engine (after startCapture) |
| `onDebug` | `Function(String)?` | Debug callback |

### BmcAudioConfig

```dart
BmcAudioConfig(
  sampleRate: 16000,  // Hz (default: 16000)
  channels: 1,        // 1=mono, 2=stereo (default: 1)
  decrypt: true,      // Enable XOR decryption (default: true)
  seed: 0xC0FFEE12,   // XOR seed (default: 0xC0FFEE12)
)
```

### BmcAudioDevice

Represents an audio capture device.

| Property | Type | Description |
|---|---|---|
| `id` | `String` | Platform device ID |
| `name` | `String` | Display name |
| `isUsb` | `bool` | Is USB audio device |
| `isBmc` | `bool` | Is BMC device (name heuristic) |
| `vendorId` | `int?` | USB VID (Android USB Direct only) |
| `productId` | `int?` | USB PID (Android USB Direct only) |

### BmcAudioCrypto

Standalone XOR crypto engine (can be used independently):

```dart
final crypto = BmcAudioCrypto(seed: 0xC0FFEE12);

// Decrypt PCM16LE buffer in-place
final encrypted = Uint8List.fromList([...]);
crypto.transformPcm16le(encrypted);  // now decrypted

// Reset keystream position
crypto.reset();

// One-shot transform (creates copy)
final decrypted = BmcAudioCrypto.transform(encrypted, seed: 0xC0FFEE12);
```

## How It Works

### Audio Capture Flow

```
┌─────────────┐
│ BMC USB AIO  │  UAC2.0 XOR-encrypted PCM16LE
└──────┬──────┘
       │
┌──────▼──────────────────────────────────┐
│            BmcAudioDecoder              │
│  ┌─────────────────────────────────┐    │
│  │  Platform Auto-Detection        │    │
│  │  Android + HAL audio → AudioRec │    │
│  │  Android + Composite → USB Isoc │    │
│  │  iOS/Win/Linux → flutter_recorder│   │
│  └──────────┬──────────────────────┘    │
│             │ Raw PCM16LE               │
│  ┌──────────▼──────────────────────┐    │
│  │  BmcAudioCrypto (DID decrypt)   │    │
│  └──────────┬──────────────────────┘    │
│             │ Clean PCM16LE             │
└──────────── ┤ ──────────────────────────┘
              │
     Stream<Uint8List>  →  Your App
```

### Android Composite USB

Android's audio HAL does not recognize USB audio interfaces within composite USB devices. This plugin solves it with:

1. **UsbManager** — detects hardware USB device by VID/PID
2. **USB permission** — auto-grant via device filter or runtime request
3. **Native JNI** — C code using `USBDEVFS_SUBMITURB` ioctl for true isochronous transfer
4. **EventChannel** — streams audio data from native thread to Dart

## Debug Logging

```dart
final decoder = BmcAudioDecoder();
decoder.onDebug = (msg) => print('[BMC] $msg');
```

## Example App

See `example/` for a complete demo app with:
- Device selection dropdown
- Start/Stop capture
- XOR decrypt toggle
- Real-time waveform visualization
- WAV file save & playback
- Debug log viewer

## License

Proprietary — BMC Technology Vietnam
