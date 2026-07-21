# bmc_audio_cli — Linux capture/decrypt CLI

Standalone tool to capture and decrypt audio from the **BMC S-USB** device on
Linux, **without any Flutter/Dart toolchain**. It runs the same pipeline as the
Flutter Linux plugin ([`../bmc_audio_plugin.cc`](../bmc_audio_plugin.cc)):

1. **libusb isochronous capture** from the audio-streaming IN endpoint —
   bypasses ALSA/PulseAudio/PipeWire so the bytes are **bit-exact** (mandatory
   for XOR decryption; the OS audio server resamples and breaks it).
2. **XOR keystream decrypt** — a C port of [`lib/src/audio_crypto.dart`](../../lib/src/audio_crypto.dart)
   (`mix32`/`keystream16`), matching firmware `source/uac/audio_crypto.c`.
3. **Offset search** to align the keystream, then writes two WAVs.

## Build & run

```bash
sudo apt install libusb-1.0-0-dev   # if not already present
cd linux/tool
make                    # -> ./bmc_audio_cli
./bmc_audio_cli -d 5    # capture 5s -> bmc_capture_enc.wav + bmc_capture_dec.wav
# or: make run
```

Options: `-d <seconds>` (default 5), `-o <basename>` (default `bmc_capture`),
`-s <seedHex>` (default `C0FFEE12`, must match firmware).

Play the result:
```bash
pw-play bmc_capture_dec.wav      # decrypted (clear audio)
pw-play bmc_capture_enc.wav      # raw encrypted (noise)
```

## Permissions

No root needed if your user is in the **`plugdev`** group (udev grants a uaccess
ACL on the device node). Otherwise run with `sudo` or add a udev rule:

```
# /etc/udev/rules.d/99-bmc-susb.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="1fc9", MODE="0660", GROUP="plugdev"
```

## Expected output

```
Endpoint: intf=4 alt=1 EP=0x87 maxpkt=32
Captured 160768 bytes (~5.02s)
Score RAW (encrypted): 0.0021
Offset found: 16  (search score 0.82)
Score DECRYPTED:       0.9464  -> clean audio :)
```

`Score` is adjacent-sample correlation: ~0 = noise/encrypted, >0.3 = real audio.
While this tool holds the device, libusb auto-detaches the kernel `snd-usb-audio`
driver; PipeWire recovers the ALSA card automatically afterwards.
