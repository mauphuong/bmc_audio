#!/usr/bin/env python3
"""Generate reference signals to play into the S-USB microphone.

Judging a microphone path by ear is unreliable: the room, the speaker and the
listener all change between takes. Playing a known signal makes the measurement
repeatable, so a firmware change can be attributed to the firmware.

    ./make_reference.py                  # writes ref_*.wav
    aplay ref_tone1k.wav                 # play through speakers, mic picks up

Signals produced:
  ref_tone1k.wav   steady 1 kHz sine    -> THD, distortion, gain staging
  ref_sweep.wav    stepped 100 Hz..7 kHz -> frequency response, filter corners
  ref_silence.wav  digital silence      -> noise floor, hum, idle tones
"""

import argparse
import wave

import numpy as np

RATE = 48000  # play out at a rate the PC sound card certainly supports


def write(path, x):
    x = np.clip(x, -1.0, 1.0)
    pcm = (x * 32000).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print(f"wrote {path}  ({len(x) / RATE:.1f}s)")


def fade(x, ms=20):
    n = int(RATE * ms / 1000)
    if len(x) < 2 * n:
        return x
    ramp = np.linspace(0, 1, n)
    x[:n] *= ramp
    x[-n:] *= ramp[::-1]
    return x


def tone(freq, secs, amp):
    t = np.arange(int(RATE * secs)) / RATE
    return fade(amp * np.sin(2 * np.pi * freq * t))


def sweep(freqs, secs_each, amp):
    return np.concatenate([tone(f, secs_each, amp) for f in freqs])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--amp", type=float, default=0.5,
                    help="playback amplitude 0..1 (default 0.5)")
    ap.add_argument("--secs", type=float, default=10.0)
    args = ap.parse_args()

    write("ref_tone1k.wav", tone(1000.0, args.secs, args.amp))

    # Steps rather than a continuous glide: each one holds long enough that a
    # single FFT resolves it cleanly, and the boundaries are easy to find.
    steps = [100, 150, 200, 300, 500, 800, 1200, 2000, 3000, 4000, 5000, 6000, 7000]
    write("ref_sweep.wav", sweep(steps, 1.0, args.amp))
    print("  sweep steps (1s each): " + ", ".join(f"{f}" for f in steps))

    write("ref_silence.wav", np.zeros(int(RATE * args.secs)))


if __name__ == "__main__":
    main()
