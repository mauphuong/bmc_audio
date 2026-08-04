# Changelog

## 0.2.0

Fixes the failure where audio turned to permanent noise part-way through a
capture on Android, and adds the machinery to recover from it generally.

### The bug

The XOR keystream is a function of a free-running sample counter on the device.
Both sides have to agree on that counter, and the decoder used to establish it
exactly once — an offset search over the first second of audio, after which the
lock was never revisited.

Isochronous transfers are never retransmitted. Lose one packet and the host's
byte stream is 16 samples short of what the device counted, so every subsequent
sample decrypts against the wrong key. The result is uniform noise, and nothing
in the old code looked for it or corrected it.

Android lost packets structurally. Its capture loop allocated a single URB,
submitted it, blocked on `REAPURB`, copied the payload out, freed everything and
only then submitted the next one. Between reaping one URB and submitting the
next there was no URB queued for the endpoint, so the host controller stopped
polling it. iOS never had the problem (its CCID path is a reliable transfer and
carries a sample index in every chunk); Linux never had it either (it has always
kept eight transfers in flight).

### Fixed

- **Android transport**: a pool of URBs now stays submitted at all times.
  `nativeIsoStart` / `nativeIsoRead` / `nativeIsoStop` replace the one-shot
  `nativeIsoRead`; reaping one URB leaves the rest covering the endpoint while
  the payload is copied out and it is resubmitted. The capture loop no longer
  allocates per read.
- **Keystream recovery**: the decrypted stream is scored continuously, and the
  keystream is re-acquired when it stops looking like audio — searching first
  near the current position, then wider, then from zero in case the device
  restarted its stream. A desync now costs about 250 ms of audio instead of the
  rest of the recording.
- **Loss reporting**: Linux and Android report isochronous packets that failed,
  so recovery starts immediately rather than waiting for the score to degrade.
- **Disconnect detection (Linux)**: a device that disappears mid-capture now
  raises `USB_DISCONNECTED` instead of the stream silently going quiet.
- **Offset search**: no longer assumes packets carry exactly 16 samples. The
  firmware's audio endpoint is asynchronous and varies the payload between 15
  and 17 samples to track the host clock, so the cumulative offset can be any
  integer; the old coarse pass stepped 16 at a time and would miss it entirely.

### Added

- `BmcAudioDecoder.resyncCount` — keystream re-acquisitions this session.
- `BmcAudioDecoder.droppedPackets` — isochronous packets the transport lost.

### Migrating from 0.1.0

The data callback is unchanged: still `Uint8List` of PCM16LE, 16 kHz, mono.
Two things need attention.

**1. Handle errors on the audio stream.** This is the only required code change.
The stream now reports conditions the decoder cannot fix by itself:

| Error | Meaning |
|---|---|
| `StateError` (`keystream could not be re-acquired…`) | four recovery attempts failed; the device has most likely gone away |
| `USB_DISCONNECTED` | device disconnected mid-capture (Linux) |
| `USB_ISO_FAIL` | isochronous transfers failing repeatedly (Android) |

A `listen` without `onError` sends these to the zone's uncaught error handler,
which surfaces as an unhandled exception. Handle them and restart the capture:

```dart
stream.listen(
  onAudio,
  onError: (Object error) async {
    await decoder.stopCapture();
    if (stillWantAudio) {
      decoder.startCapture().listen(onAudio, onError: ...);
    }
  },
);
```

**2. Rebuild the native library.** The Android JNI entry points changed, so a
stale `libbmc_usb_audio.so` will fail to link at runtime. Run `flutter clean`
before the first build against this version.

Nothing else in the API changed, and no configuration is required to get the
recovery behaviour — it is on by default.

## 0.1.0

* Initial release.
