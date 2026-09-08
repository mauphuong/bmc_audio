# Changelog

## 0.2.2

Fixes `CCID_CONNECT_FAILED` on iOS when a call arrives with the S-USB already
plugged in, while the same device signs and reads files without trouble.

### The bug

`CcidAudioBridge.connect()` was a single shot: list the slots, take the first
one that hands back a card, begin a session, and report failure the moment any
of that does not work out. That is a race against the system.

The CCID slot of the composite device is not continuously available. When a call
starts on a device that is already plugged in, CallKit activates the audio
session and iOS claims the UAC interface of the same device — CryptoTokenKit
re-probes the card around that. For that window `slotNames` can be empty,
`slot.state` is `.probing`, or `makeSmartCard()` returns nil. Plugging the device
in *during* a call has none of this: the audio session is already up, nothing is
re-attaching, and the first probe succeeds. Hence the asymmetric repro — the same
call fails when the device was plugged in first and works when it is plugged in
later.

Nothing in the failure path said which stage failed. Slots that did not yield a
card were skipped with a bare `continue`, and an empty slot list returned false
without a line of log, so every cause arrived at the host as one opaque
`Could not connect to smart card`.

### Fixed

- **Connect retries across the re-attach window.** `connect(maxAttempts:
  retryDelay:)` probes 12 times at 250 ms — about three seconds — instead of
  giving up on the first miss. `reconnect()` uses a shorter window because the
  polling loop already wraps it in retries of its own.
- **`slot.state` is checked.** `.validCard` is required before
  `makeSmartCard()`; `.probing` is now a state to wait out rather than a silent
  skip.
- **Every failure path is named.** Slot list empty, `getSlot` nil or timed out,
  wrong card state, `makeSmartCard()` nil, `beginSession` error — each is logged
  and recorded in `lastConnectError`, which travels to Dart in the
  `CCID_CONNECT_FAILED` message and details. A field report now says whether the
  card was busy, absent, or still probing.
- **`beginSession` no longer waits forever.** Another `TKSmartCard` holding the
  card — a signing session that was not closed — made it queue indefinitely, and
  the unbounded semaphore wait hung the calling thread with it. Both waits in
  connect are bounded (3 s for `getSlot`, 5 s for `beginSession`).
- **Connect runs off the platform thread.** Seconds of retries on the Flutter
  platform thread would freeze the call screen, so `startCcidCapture` connects on
  its own queue and resumes on main. A start whose connect was still running when
  the call ended is invalidated by a token check, so it cannot come back and hold
  the microphone and the card.

## 0.2.1

Fixes iOS transmitting noise instead of audio when a call is answered from the
lock screen with the device already plugged in.

### The bug

CCID is the only bit-exact capture path on iOS — CoreAudio's Float32 pipeline
resamples, which destroys the XOR keystream. The decoder chose it with:

```dart
useIosCcid = !isAndroid && resolvedDecrypt && (device?.isBmc ?? false);
```

`isBmc` came solely from matching the AVAudioSession port name against
`s-usb` / `bmc audio` / `aio` / `bmc mic`. In the background the session belongs
to CallKit, `availableInputs` yields nothing, and the lookup returns no device
at all — so the condition went false while decryption stayed on. Capture then
ran over AVAudioEngine and XOR-ed a resampled stream: white noise, sent to the
far end for the whole call. Nothing failed. Capture started, chunks flowed, the
first chunk satisfied the caller's readiness check, and the call connected.

Two further faults made the background case worse. `listAudioDevices()`
reconfigured and activated the shared session purely to enumerate, disturbing
the route CallKit had set for the call; and `stopCcidCapture()` tore the session
down unconditionally, so the decoder reset that hosts perform before every call
deactivated a session CallKit owned — which drops the USB port from
`currentRoute` and reads as a phantom detach.

### Fixed

- **Device identity from IORegistry, not port names.** `listAudioDevices()` asks
  IOKit for VID `0x1FC9` first; that works with no audio session and on a locked
  device. A USB audio port is reported as BMC whenever the hardware is on the
  bus, and when the session exposes no port at all the device is still reported,
  synthesised from the registry. USB product strings are no longer trusted to
  contain a recognisable name.
- **Decryption implies CCID on iOS.** `useIosCcid` is now `isIOS && decrypt`.
  Device detection no longer sits between "decrypt was requested" and "use the
  only path that can honour it". Failing to open CCID raises; guessing does not.
- **Tripwire against lossy decryption.** Reaching the platform capture path with
  decryption on now throws on iOS and warns elsewhere, so this class of bug
  reports itself instead of sounding like broken hardware.
- **`isBmc` from the native layer is honoured.** Dart recomputed it from the
  name and discarded what the platform reported.
- **Session ownership.** Device listing leaves an existing `.playAndRecord`
  session untouched and only restores what it configured itself;
  `stopCcidCapture()` is a no-op when nothing is capturing.

### Removed

- **`flutter_recorder`, and with it desktop capture.**

  From 1.2.0 the package vendors `opus.xcframework` on iOS. Host apps that also
  depend on `opus_flutter_ios` — which vendors a framework of the same name —
  cannot run `pod install` at all: *"the 'Pods-Runner' target has frameworks with
  conflicting names: opus.xcframework"*. Upstream namespaced its Android
  libraries as `libfr_ogg`/`libfr_opus` for exactly this reason; the iOS
  framework kept the bare name.

  `flutter_recorder` backed desktop capture only. Android, iOS and Linux go
  through native capture paths and never touched it, so every iOS build was
  paying — and now failing — for a dependency none of its code uses.

  **Breaking on Windows and macOS**: the stream returned by `startCapture()`
  emits `UnsupportedError` there, and device enumeration returns empty. Callers
  on those platforms need the commit reverted, or a desktop backend that does
  not put a CocoaPods dependency in front of iOS.

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
- **iOS background noise (firmware fix)**: the CCID audio path prepends the
  sample index to every read so the host always knows which keystream offset
  applies. That index and the keystream itself were reset independently — the
  CCID start-stream command reset both, but `UAC2_AppPrimeStream()` reset only
  the keystream. Priming runs on every SET_INTERFACE to the streaming alt
  setting, which on iOS happens whenever the `AVAudioEngine` holding the
  endpoint open is restarted: session interruptions, route changes, moving to
  the background. After such a restart the ring still reported a large sample
  index for data that had been encrypted starting from zero again, and
  everything the host decrypted was noise until the app restarted the stream.
  The ring is now flushed and re-based whenever the keystream resets.
  **Requires reflashing the device.**
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

**3. iOS only — declare the background audio mode.** Add to `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

The UAC endpoint on iOS is kept alive by an `AVAudioEngine` instance; the
firmware only produces packets while the host is streaming, and the CCID bridge
only has data to read while that is true. Without this key iOS suspends the app
when it goes to the background or the screen locks, the engine stops, and audio
stops with it. `NSMicrophoneUsageDescription` is required as well.

**4. iOS only — reflash the firmware.** See below; the fix for background noise
is on the device side and cannot be worked around in the app.

Nothing else in the API changed, and no configuration is required to get the
recovery behaviour — it is on by default.

## 0.1.0

* Initial release.
