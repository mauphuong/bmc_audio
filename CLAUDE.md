# CLAUDE.md

Hướng dẫn cho Claude Code khi làm việc trong repo này.

## Tổng quan

`bmc_audio` là một **Flutter plugin** để **thu và giải mã (decrypt) âm thanh** từ thiết bị
**BMC S-USB Pro** — một thiết bị USB composite (MSC + CCID + HID + UAC2.0) do BMC Technology
Vietnam sản xuất. Luồng audio UAC2.0 của thiết bị được firmware **mã hoá bằng XOR keystream**;
plugin này thu PCM16LE từ endpoint audio và giải mã lại thành audio sạch.

- Nguồn audio: thiết bị BMC **VID = `0x1FC9`**, PID điển hình `0x0117` (composite UAC).
- Định dạng audio mặc định: **PCM16LE, 16 kHz, mono** (khớp firmware).
- Bản chất "giải mã": XOR từng sample 16-bit với keystream sinh từ `seed` — **đối xứng** (áp
  dụng 2 lần thì ra lại dữ liệu gốc), phải khớp chính xác thuật toán firmware.

Phần firmware đối ứng nằm ở working directory thứ hai:
`/run/media/mvp/.../bmc/bmc_msc_ccid_hid_uac_bm` — file tham chiếu quan trọng nhất là
[`source/uac/audio_crypto.c`](../../USB2025/USB-Audio/SC/bmc/bmc_msc_ccid_hid_uac_bm/source/uac/audio_crypto.c).
**Bất kỳ thay đổi nào ở thuật toán crypto trong Dart phải khớp bit-exact với firmware.**

## Kiến trúc: đây là "federated-ish" plugin

Package vừa là **federated plugin** (có `platform_interface` / `method_channel` / `web`) **vừa**
chứa một **API cấp cao độc lập** trong [`lib/src/`](lib/src/). Trên thực tế:

- Các file `bmc_audio_platform_interface.dart` / `bmc_audio_method_channel.dart` /
  `bmc_audio_web.dart` chỉ là bộ khung mặc định của template plugin (chỉ có `getPlatformVersion`).
  **API thật mà app dùng nằm ở `lib/src/`.**
- API công khai được export qua [`lib/bmc_audio.dart`](lib/bmc_audio.dart):
  `BmcAudioDecoder`, `BmcAudioCrypto`, `BmcAudioDevice`, `BmcAudioConfig`.

### Ba lớp chính (Dart)

| File | Class | Vai trò |
|---|---|---|
| [`lib/src/audio_decoder.dart`](lib/src/audio_decoder.dart) | `BmcAudioDecoder`, `BmcAudioConfig`, `BmcCaptureState` | API chính. Chọn device, start/stop capture, điều phối đường capture theo platform, chạy decrypt. |
| [`lib/src/audio_crypto.dart`](lib/src/audio_crypto.dart) | `BmcAudioCrypto` | Port thuần Dart của `audio_crypto.c`: `mix32`, `keystream16`, `transformPcm16le`, cộng thêm **offset search** (`searchOffset`, `scoreAudioLike`). |
| [`lib/src/audio_device.dart`](lib/src/audio_device.dart) | `BmcAudioDevice` | Model device + heuristic nhận diện USB/BMC theo tên. |

### Kênh giao tiếp native

Cả Android và iOS dùng chung tên kênh:
- MethodChannel: **`bmc_audio`**
- EventChannel (stream PCM): **`bmc_audio/audio_stream`**

## Điểm mấu chốt: mỗi platform thu audio một kiểu khác nhau

`BmcAudioDecoder.startCapture()` phân nhánh theo platform. Đây là phần dễ gây nhầm nhất — đọc kỹ:

### Android — 2 đường capture ([`BmcAudioPlugin.kt`](android/src/main/kotlin/com/bmc/audio/bmc_audio/BmcAudioPlugin.kt))

1. **USB Direct (isochronous)** — dùng khi `BmcAudioDevice` có `vendorId`/`productId`.
   Android Java USB API **không hỗ trợ isochronous transfer**, nên plugin lấy file descriptor
   từ `UsbDeviceConnection.getFileDescriptor()` rồi gọi xuống **JNI C**
   ([`android/src/main/jni/usb_audio_iso.c`](android/src/main/jni/usb_audio_iso.c)) dùng
   `USBDEVFS_SUBMITURB`/`REAPURB` ioctl để đọc thẳng endpoint. Đây là đường tin cậy nhất cho
   audio mã hoá (vì `AudioRecord` bị HAL resample/xử lý → hỏng XOR).
2. **AudioRecord** — đường chuẩn cho device được Android audio HAL nhận diện.

Native lib tên `bmc_usb_audio` (build bằng CMake + NDK, ABI: arm64-v8a, armeabi-v7a, x86_64).
`listDevices` merge **AudioManager** (input devices) + **UsbManager** (USB composite) và tự
enrich VID/PID để mở đường USB Direct.

### iOS — 3 chế độ, quan trọng nhất là CCID ([`BmcAudioPlugin.swift`](ios/Classes/BmcAudioPlugin.swift))

1. **AVAudioEngine (standard)** — đi qua CoreAudio pipeline Float32, **lossy** → phá vỡ giải mã XOR.
   Dùng cho device không phải BMC / không cần decrypt.
2. **CCID Audio Bridge** ⭐ — đường dùng khi *device BMC + decrypt ON*. Bỏ qua CoreAudio hoàn
   toàn: đọc **PCM16LE mã hoá bit-exact** từ ring buffer firmware qua **CryptoTokenKit** (smart
   card APDU). Xem [`CcidAudioBridge.swift`](ios/Classes/CcidAudioBridge.swift).
   - Vẫn phải chạy `AVAudioEngine` (tap câm, data bị vứt) để **giữ endpoint UAC sống** → firmware
     mới sinh packet → mới có dữ liệu để CCID đọc.
   - Protocol APDU: `CLA=0xB0`, INS `0xA0`=control, `0xA2`=read, `0xA4`=status.
3. **USB Direct (IOKit)** — **không khả dụng trên iOS** (IOUSBLib chỉ có ở macOS SDK; cần
   DriverKit trên iPadOS M-series). Xem [`BmcUsbHelper.m`](ios/Classes/BmcUsbHelper.m) — chỉ dùng
   IORegistry để liệt kê VID/PID.

### Linux — libusb isochronous ([`linux/bmc_audio_plugin.cc`](linux/bmc_audio_plugin.cc)) ⭐

Native plugin đọc **isochronous trực tiếp** endpoint audio (`0x87`) qua **libusb** — đúng bản
Linux của cách Android làm (Android dùng `USBDEVFS` ioctl; libusb bọc chính cơ chế đó). Bỏ qua
hoàn toàn ALSA/PulseAudio/**PipeWire** để bytes **bit-exact** (server audio resample → phá XOR).
`libusb_set_auto_detach_kernel_driver` tự gỡ `snd-usb-audio`; không cần root nếu user thuộc nhóm
`plugdev`. Trong Dart, Linux đi **cùng đường USB-direct với Android** (`_hasNativePlugin` gồm cả
Linux; `isUsbDirect` cho Linux).

CLI test độc lập (không cần Flutter): [`linux/tool/bmc_audio_cli.c`](linux/tool/bmc_audio_cli.c) —
`cd linux/tool && make run` → thu + giải mã + xuất WAV. Hữu ích để kiểm chứng phần cứng nhanh.

### Windows / macOS — flutter_recorder

Dùng package **`flutter_recorder`** (miniaudio) qua `Recorder.instance`. Lưu ý: nếu OS/driver
**resample** luồng 16 kHz thì XOR sẽ hỏng — cần đường bit-exact (WASAPI exclusive / native)
tương tự Linux. Các file plugin Windows/macOS hiện chỉ là stub template `getPlatformVersion`.

## Đồng bộ keystream — phần dễ sai nhất

XOR decrypt chỉ đúng nếu **sample index của keystream khớp** với firmware. Ba tình huống:

- **Android USB Direct, Linux libusb & Windows/macOS**: app bắt đầu đọc khi firmware đã stream
  được một số sample chưa biết trước. → Dùng **offset search**: buffer ~1 giây audio đầu
  (`_offsetSearchMinBytes = 32000`), thử các offset và chấm điểm "giống audio thật" bằng tương
  quan sample liền kề (`scoreAudioLike`), chọn offset tốt nhất. Logic ở `_processRawPcm` +
  `BmcAudioCrypto.searchOffset`. (Trên Linux thực đo: offset ≈ 16, score giải mã ~0.94.)
- **iOS CCID mode**: firmware **reset `sampleIndex = 0`** khi `startStream`, và mỗi chunk CCID
  có **header 4 byte little-endian là sampleIndex** đứng trước PCM. → **Bỏ qua offset search**;
  parse header để set `sampleIndex` trước khi decrypt (self-synchronizing). Cờ `_ccidMode`.
- Khi decrypt tắt hoặc bật lại giữa chừng, `BmcAudioCrypto` **reset keystream về 0** để giữ
  alignment xác định (khớp `AudioCrypto_SetEnabled()` firmware).

`seed` mặc định = **`0xC0FFEE12`** (`BmcAudioCrypto.defaultSeed`), phải khớp
`AUDIO_USB_ENCRYPT_SEED` của firmware.

## Auto-detect / zero-config

- `findBestDevice()`: ưu tiên **BMC > USB > mic mặc định** (luôn trả về device nếu có).
- `BmcAudioConfig.decrypt`:
  - `null` (mặc định) = **auto** → decrypt nếu device là BMC, raw nếu không.
  - `true`/`false` = ép bật/tắt.
- Nhận diện BMC theo tên (`BmcAudioDevice.looksLikeBmc`): chứa `s-usb`, `bmc audio`, `aio`,
  `bmc mic`. Nhận diện USB: chứa `usb`, `external`, `uac`.

## Lệnh thường dùng

```bash
# Phân tích tĩnh (lint) — dùng flutter_lints
flutter analyze

# Test Dart — test/bmc_audio_test.dart phủ toàn bộ BmcAudioCrypto
# (mix32, keystream16, đối xứng encrypt/decrypt, reset, offset, tính parity với firmware)
flutter test

# Chạy example app (thư mục example/)
cd example
flutter run -d windows      # hoặc: android | ios | linux | macos
flutter run -d <device-id>

# Test native Android (unit test Kotlin)
cd android && ./gradlew test
```

> Package này chưa xuất bản lên pub.dev — dùng qua `path:` dependency. `version` trong
> `pubspec.yaml` là `0.1.0` nhưng `CHANGELOG.md`/podspec vẫn ghi `0.0.1` (chưa cập nhật).

## Cấu hình platform (cho app dùng plugin)

- **Android**: cần `RECORD_AUDIO`; nên khai báo `usb.host` + `device_filter.xml`
  (`vendor-id="8137"` = `0x1FC9`) để auto-cấp quyền USB. Xem [README.md](README.md).
- **iOS**: cần `NSMicrophoneUsageDescription`. Frameworks: `AVFoundation`, `CoreAudio`, `IOKit`,
  `CryptoTokenKit` (khai báo trong [`ios/bmc_audio.podspec`](ios/bmc_audio.podspec)).

## Quy ước & lưu ý khi sửa code

- **Crypto = nguồn sự thật là firmware.** Trước khi sửa `audio_crypto.dart`, đối chiếu
  `source/uac/audio_crypto.c`. Dart `int` là 64-bit nên phải mask `& 0xFFFFFFFF` và dùng `_mul32`
  (nhân 32-bit không tràn) — đừng "đơn giản hoá" phần này.
- `BmcAudioDecoder` là **stateful**: `startCapture` ném `StateError` nếu chưa `idle`. Luôn
  `stopCapture()` trước khi start lại, và `dispose()` khi xong.
- Output là **broadcast stream** `Stream<Uint8List>`; khi listener cuối cancel sẽ tự `stopCapture`.
- Đặt `decoder.onDebug` để nhận log pipeline (rất hữu ích khi debug vì USB đang bị chiếm bởi
  device — example app in log ra màn hình thay vì console).
- Comment trong code (nhất là iOS Swift) ghi lại nhiều **bẫy CoreAudio** đã fix: format 0 Hz gây
  crash `installTap`, `.measurement` mode giết audio player khác, `setActive(false)` gây "fake
  DETACH" USB. **Đừng xoá các fix này** — chúng vá lỗi thực tế trên thiết bị.
- Comment/log trong repo trộn Anh–Việt; giữ nguyên phong cách file đang sửa.

## Bố cục thư mục

```
lib/
  bmc_audio.dart                     # export công khai
  bmc_audio_{platform_interface,method_channel,web}.dart   # khung federated (chỉ getPlatformVersion)
  src/audio_{decoder,crypto,device}.dart                   # API thật
android/src/main/
  kotlin/.../BmcAudioPlugin.kt       # AudioRecord + USB Direct + UsbManager
  jni/usb_audio_iso.c                # isochronous read qua USBDEVFS ioctl (JNI)
ios/Classes/
  BmcAudioPlugin.swift               # AVAudioEngine + điều phối CCID
  CcidAudioBridge.swift              # đọc PCM mã hoá qua CryptoTokenKit (APDU)
  BmcUsbHelper.{h,m}                 # liệt kê USB qua IOKit registry (không transfer được)
linux/
  bmc_audio_plugin.cc                # libusb isochronous capture (EP 0x87), bit-exact
  CMakeLists.txt                     # link libusb-1.0
  tool/bmc_audio_cli.c               # CLI test độc lập (không cần Flutter): capture+decrypt+WAV
{windows,macos}/                    # plugin stub (getPlatformVersion); audio dùng flutter_recorder
example/                            # app demo: chọn device, waveform, lưu & phát WAV
```
