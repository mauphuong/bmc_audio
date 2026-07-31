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

## Audio quality measurement

`audio_test.sh` captures through the isochronous endpoint, decrypts, and runs
`analyze_wav.py` over the result. Captures land in `captures/` with a timestamp
so runs can be compared — comparing two runs is the point, since absolute
numbers from a room microphone depend on the room.

### Acoustic tests (signal played through speakers)

```bash
./audio_test.sh room  10    # ambient: noise floor, rumble, mains hum
./audio_test.sh tone  10    # 1 kHz sine -> THD, clipping
./audio_test.sh sweep 20    # stepped tones -> rough frequency response
```

These measure the loudspeaker and the room as well as the firmware, so they
cannot attribute a change to our code on their own.

### Injected tests (no speakers involved)

Set `PDM_TEST_SIGNAL` in `source/uac/usb_audio_config.h`, rebuild and reflash.
The firmware then substitutes a known waveform for the microphone samples,
immediately before the DSP chain. The capture ring, rate controller, encryption
and USB path all stay exactly as in normal operation, so anything wrong in the
recording is unambiguously ours.

| `PDM_TEST_SIGNAL` | Signal | Measures |
|---|---|---|
| 1 | sine at `PDM_TEST_TONE_HZ` | THD, gain accuracy |
| 2 | stepped sweep 50 Hz–7 kHz | frequency response, filter corners |
| 3 | digital silence | noise the DSP itself adds |
| 4 | full-scale sine | limiter / soft-clip behaviour |

```bash
./audio_test.sh inject-tone    10   # needs PDM_TEST_SIGNAL=1
./audio_test.sh inject-sweep   20   # needs PDM_TEST_SIGNAL=2 (15 steps x 1 s)
./audio_test.sh inject-silence 10   # needs PDM_TEST_SIGNAL=3
```

`inject-sweep` prints the response of the DSP chain directly. With the default
high-pass (`PDM_HPF_SHIFT=5`, `PDM_HPF_STAGES=2`) expect roughly -11 dB at
50 Hz and flat from 500 Hz to 7 kHz; a strong rolloff at the top means
`PDM_LPF_ENABLE` is still set.

Remember to set `PDM_TEST_SIGNAL` back to 0 before shipping.
