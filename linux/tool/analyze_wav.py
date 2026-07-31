#!/usr/bin/env python3
"""Objective quality report for a mono PCM16 capture from the BMC S-USB.

Turns "it sounds worse" into numbers that point at a specific stage of the
pipeline. Run it on a WAV produced by bmc_audio_cli:

    ./bmc_audio_cli -d 10 -o take1
    ./analyze_wav.py take1_decrypted.wav

Add --tone 1000 when a known sine is being played into the microphone; that
enables THD+N and a distortion verdict, which is the only way to separate
"the microphone hears a noisy room" from "our gain staging is clipping".
"""

import argparse
import sys
import wave

import numpy as np

FULL_SCALE = 32768.0


def db(x, floor=1e-12):
    return 20.0 * np.log10(max(float(x), floor) / FULL_SCALE)


def load(path):
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            sys.exit(f"{path}: expected 16-bit samples")
        if w.getnchannels() != 1:
            sys.exit(f"{path}: expected mono")
        rate = w.getframerate()
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float64), rate


def section(title):
    print(f"\n── {title} " + "─" * max(0, 54 - len(title)))


def report_levels(x):
    section("Levels")
    # Measured on steady state only. A stale packet left in the USB controller
    # from a previous session lands in the first millisecond and pins peak to
    # full scale, which makes both peak and crest factor meaningless.
    full = x
    x = steady_state(x)
    if x.size < full.size:
        raw_peak = np.abs(full[:STARTUP_SAMPLES]).max()
        print(f"(startup peak {raw_peak:.0f} excluded — warmup + stale packet)")

    peak = np.abs(x).max() if x.size else 0.0
    rms = np.sqrt(np.mean(x**2)) if x.size else 0.0
    dc = x.mean() if x.size else 0.0

    print(f"peak      {peak:8.0f}  ({db(peak):6.1f} dBFS)")
    print(f"RMS       {rms:8.0f}  ({db(rms):6.1f} dBFS)")
    print(f"DC offset {dc:8.1f}  ({dc / FULL_SCALE * 100:+.3f} % FS)")
    print(f"crest     {db(peak) - db(rms):8.1f} dB")

    if peak < 1000:
        print("  NOTE: very quiet — is the microphone picking anything up?")
    if abs(dc) > 100:
        print("  WARNING: DC offset is large; the DC remover is not converging")
    return peak


def report_clipping(x):
    x = steady_state(x)
    section("Clipping / saturation")
    n = x.size
    at_max = int(np.sum((x >= 32767) | (x <= -32768)))
    near = int(np.sum(np.abs(x) > 32767 * 0.99))

    print(f"samples at full scale : {at_max:8d}  ({100.0 * at_max / n:.4f} %)")
    print(f"samples above 99 % FS : {near:8d}  ({100.0 * near / n:.4f} %)")

    # Consecutive samples pinned to the rail are the signature of a limiter
    # being driven far past its knee, which is what turns loud speech to mush.
    pinned = np.abs(x) > 32767 * 0.995
    runs, longest, cur = 0, 0, 0
    for v in pinned:
        if v:
            cur += 1
        else:
            if cur > 1:
                runs += 1
                longest = max(longest, cur)
            cur = 0
    print(f"flat-top runs (>1 smp): {runs:8d}   longest {longest} samples")

    if at_max > n * 0.001:
        print("  WARNING: hard clipping. Reduce PDM_SW_GAIN_SHIFT in pdm_audio.c")
    elif runs > 20:
        print("  WARNING: limiter is engaging often. Lower the gain or raise "
              "PDM_SOFT_CLIP_KNEE")


# Firmware holds output at silence for PDM_WARMUP_SAMPLES then fades in over
# PDM_FADEIN_SAMPLES. A stale packet left in the USB controller from a previous
# session can also land in front of that. None of it is steady-state audio, so
# it is excluded rather than counted as damage.
STARTUP_SAMPLES = 1600 + 4096


def steady_state(x):
    return x[STARTUP_SAMPLES:] if x.size > STARTUP_SAMPLES * 2 else x


def report_glitches(x, rate):
    section("Continuity")
    y = steady_state(x)
    if y.size < 3:
        return
    if y.size < x.size:
        print(f"(skipping first {STARTUP_SAMPLES} samples: warmup + fade-in)")

    d = np.abs(np.diff(y))
    med = np.median(d)
    # A dropout or a keystream slip produces a step far outside the normal
    # sample-to-sample range of the signal.
    thresh = max(2000.0, med * 40)
    idx = np.nonzero(d > thresh)[0]
    per_sec = idx.size / (y.size / rate)

    print(f"median adjacent diff  : {med:8.1f}")
    print(f"steps above {thresh:7.0f}  : {idx.size:8d}  ({per_sec:.1f}/s)")

    runs = int(np.sum(y[:-1] == y[1:]))
    print(f"repeated samples      : {runs:8d}  ({100.0 * runs / y.size:.2f} %)")

    zeros = int(np.sum(y == 0))
    print(f"exact zeros           : {zeros:8d}  ({100.0 * zeros / y.size:.2f} %)")

    if idx.size:
        t = (idx[:8] + STARTUP_SAMPLES) / rate
        print("  first glitches at: " + ", ".join(f"{v:.3f}s" for v in t))

    # Speech transients are legitimately steep, so only a sustained rate of
    # steps points at the transport. Cross-check against the packet counters
    # bmc_audio_cli prints before trusting this.
    if per_sec > 20:
        print(f"  WARNING: {per_sec:.0f} discontinuities/s — check the failed "
              "packet count reported by bmc_audio_cli")
    if zeros > y.size * 0.2:
        print("  NOTE: lots of digital silence — capture ring underrunning, or "
              "the noise gate is still enabled")


def report_spectrum(x, rate):
    section("Spectrum")
    x = steady_state(x)
    if x.size < 2048:
        print("too short")
        return

    n = 4096
    win = np.hanning(n)
    raw_frames = [x[i:i + n] for i in range(0, x.size - n, n // 2)]
    if not raw_frames:
        return

    # Average over frames that carry signal, excluding only silence. This used
    # to keep the loudest quarter of frames, which is actively misleading on
    # speech: the loudest frames are vowels, vowels have essentially no energy
    # above 4 kHz, and the fricatives that do carry it are quiet. The result
    # was a capture reporting 0.2 % above 4 kHz while individual frames in it
    # were 77 % above 4 kHz -- and a note blaming the low-pass filter for it.
    #
    # Gate against the noise floor instead, so quiet-but-real content counts.
    energies = np.array([np.sqrt(np.mean(f**2)) for f in raw_frames])
    floor = np.percentile(energies, 10)
    gate = max(floor * 3.0, energies.max() * 0.02)
    active = [f for f, e in zip(raw_frames, energies) if e >= gate]
    if len(active) < 3:
        active = raw_frames
    print(f"(averaged over {len(active)}/{len(raw_frames)} frames above the "
          f"noise floor)")

    freq = np.fft.rfftfreq(n, 1.0 / rate)
    spec = np.mean([np.abs(np.fft.rfft(f * win)) ** 2 for f in active], axis=0)

    # Peak per-frame high-frequency share. On speech this is the honest test of
    # whether the top octaves survive the chain: one fricative up in the tens of
    # percent proves they do, however small their share of the whole recording.
    #
    # Measured on a much shorter frame than the averaged spectrum. A fricative
    # lasts well under 100 ms, so a 4096-sample (256 ms) window smears it
    # together with the neighbouring vowel and silence -- enough to turn a frame
    # that is genuinely 78 % high-frequency into a reported 8 %.
    short = 1024
    short_win = np.hanning(short)
    short_freq = np.fft.rfftfreq(short, 1.0 / rate)
    hf_bins = short_freq >= 4000

    short_frames = [x[i:i + short] for i in range(0, x.size - short, short // 2)]
    short_rms = np.array([np.sqrt(np.mean(f**2)) for f in short_frames])

    # Deliberately permissive, and derived from the short frames rather than
    # reusing the spectrum gate. Fricatives are quiet -- in a capture of
    # continuous speech the 10th percentile is already loud enough that a gate
    # built from it excludes them, which hid a 78 % frame and left this
    # reporting 3 %. Here the gate only has to reject digital silence.
    short_gate = max(np.percentile(short_rms, 5) * 2.0, short_rms.max() * 0.01)

    peak_hf = 0.0
    for f, r in zip(short_frames, short_rms):
        if r < short_gate:
            continue
        s = np.abs(np.fft.rfft(f * short_win)) ** 2
        t = s.sum()
        if t > 0:
            peak_hf = max(peak_hf, 100.0 * s[hf_bins].sum() / t)

    total = spec.sum()
    if total <= 0:
        print("silent")
        return

    print("band energy share:")
    edges = [0, 300, 1000, 2000, 3000, 4000, 6000, 8000]
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (freq >= lo) & (freq < hi)
        share = 100.0 * spec[m].sum() / total
        bar = "█" * int(share / 2)
        print(f"  {lo:5d}-{hi:5d} Hz  {share:5.1f} %  {bar}")

    # The low-pass filter this project used to run had its -3 dB point around
    # 2.5-3 kHz, so a capture made with it shows almost nothing above 4 kHz.
    lf = 100.0 * spec[freq < 100].sum() / total
    hf = 100.0 * spec[(freq >= 4000)].sum() / total
    print(f"\nbelow 100 Hz: {lf:.1f} %   above 4 kHz: {hf:.1f} % "
          f"(peak in any one frame: {peak_hf:.0f} %)")

    # Rumble and mains hum sit here. They carry no speech, they eat headroom,
    # and with the noise gate off they are continuously audible. The firmware's
    # high-pass cascade (PDM_HPF_SHIFT / PDM_HPF_STAGES) is what controls this.
    if lf > 25.0:
        print(f"  WARNING: {lf:.0f} % of energy is below 100 Hz — rumble is "
              "dominating. Lower PDM_HPF_SHIFT in pdm_audio.c (5 -> 4) to "
              "raise the high-pass corner")
    # Only meaningful when there is mid-band content to compare against: in a
    # capture that is nothing but rumble, an empty top octave says nothing
    # about the filter settings. Use the sweep test to answer this properly.
    # Judge the top octave on the best frame, not the average. A recording can
    # legitimately average near zero up here -- vowels carry almost nothing
    # above 4 kHz -- while the chain passes it perfectly, which any fricative
    # in the capture will show. Only conclude the band is missing when no frame
    # anywhere has it.
    mid = 100.0 * spec[(freq >= 300) & (freq < 3000)].sum() / total
    if peak_hf < 5.0 and mid > 20.0 and lf < 40.0:
        print("  NOTE: no frame anywhere carries much above 4 kHz — check "
              "PDM_LPF_ENABLE, then confirm with PDM_TEST_SIGNAL=2 which "
              "measures the DSP chain directly")
    elif hf < 1.0 and peak_hf >= 5.0:
        print(f"  (Top octave averages low but reaches {peak_hf:.0f} % on the "
              "best frame — normal for speech, where only fricatives use it.)")
    if hf > 45.0:
        print("  NOTE: very HF-heavy — this is hiss, not speech. Check gain "
              "staging before blaming the LPF removal")

    # 50/60 Hz mains pickup is a common cause of "it sounds bad" that has
    # nothing to do with any of the DSP settings.
    for f0 in (50.0, 60.0):
        m = (freq > f0 - 5) & (freq < f0 + 5)
        share = 100.0 * spec[m].sum() / total
        if share > 2.0:
            print(f"  WARNING: {f0:.0f} Hz mains hum present ({share:.1f} %)")


def report_tone(x, rate, f0):
    section(f"Tone test @ {f0:.0f} Hz")
    n = min(x.size, 1 << int(np.floor(np.log2(x.size))))
    seg = x[:n] * np.hanning(n)
    spec = np.abs(np.fft.rfft(seg))
    freq = np.fft.rfftfreq(n, 1.0 / rate)

    def bin_energy(target, width=30.0):
        m = (freq > target - width) & (freq < target + width)
        return float(np.sum(spec[m] ** 2))

    fund = bin_energy(f0)
    if fund <= 0:
        print("fundamental not found — is the tone actually reaching the mic?")
        return

    harm = 0.0
    print("harmonics (relative to fundamental):")
    for k in range(2, 8):
        fk = f0 * k
        if fk >= rate / 2:
            break
        e = bin_energy(fk)
        harm += e
        print(f"  H{k} @ {fk:6.0f} Hz : {10 * np.log10(max(e / fund, 1e-12)):6.1f} dB")

    total = float(np.sum(spec**2))
    noise = max(total - fund, 1e-12)

    thd = np.sqrt(harm / fund) * 100
    thdn = np.sqrt(noise / fund) * 100
    print(f"\nTHD    {thd:6.2f} %")
    print(f"THD+N  {thdn:6.2f} %  (SNR {10 * np.log10(fund / noise):.1f} dB)")

    if thd > 5.0:
        print("  WARNING: heavy harmonic distortion — the soft clipper or the "
              "hard limiter is being driven into. Lower PDM_SW_GAIN_SHIFT")
    elif thd > 1.0:
        print("  NOTE: mild distortion; acceptable for voice, not for tones")


# Must match s_testSweepHz[] in firmware pdm_audio.c.
INJECT_SWEEP_HZ = [50, 80, 100, 150, 200, 300, 500, 800,
                   1200, 2000, 3000, 4000, 5000, 6000, 7000]


def report_sweep(x, rate, hold_secs=1.0):
    """Frequency response from an injected stepped sweep.

    With PDM_TEST_SIGNAL=2 the firmware substitutes a known constant-amplitude
    sine for the microphone, stepping through INJECT_SWEEP_HZ. Every step goes
    in at the same level, so the level that comes out *is* the response of the
    DSP chain -- no loudspeaker or room in the way.
    """
    section("Injected sweep — frequency response")
    hold = int(rate * hold_secs)
    x = steady_state(x)

    nsteps = len(INJECT_SWEEP_HZ)

    def segments(off):
        out = []
        for k in range(nsteps):
            seg = x[off + k * hold: off + (k + 1) * hold]
            if seg.size < hold:
                return None
            # Discard the edges: a step boundary inside the window would drag
            # both the level and the measured frequency towards the neighbour.
            out.append(seg[hold // 8: -hold // 8])
        return out

    def level(seg):
        return float(np.sqrt(np.mean(seg**2)))

    def dominant_hz(seg):
        spec = np.abs(np.fft.rfft(seg * np.hanning(seg.size)))
        return float(np.fft.rfftfreq(seg.size, 1.0 / rate)[int(np.argmax(spec))])

    # The capture starts at an arbitrary point in a sweep that repeats forever,
    # so alignment has two unknowns: where the step boundary falls, and which
    # step we landed on. Matching on level cannot resolve the second -- every
    # cyclic rotation of the sequence has the same level statistics, so an
    # earlier version of this silently reported the response rotated by one
    # step. Match on the measured frequency of each segment instead, which is
    # unambiguous.
    best = None
    step_probe = max(hold // 16, 1)
    margin = x.size - nsteps * hold
    if margin < 0:
        print(f'capture too short — need {nsteps * hold_secs + 2:.0f}s after warmup')
        return
    for off in range(0, min(hold, margin + 1), step_probe):
        segs = segments(off)
        if segs is None:
            continue
        freqs = [dominant_hz(s) for s in segs]

        for rot in range(nsteps):
            expected = INJECT_SWEEP_HZ[rot:] + INJECT_SWEEP_HZ[:rot]
            errs = [abs(np.log2(max(m, 1.0) / e)) for m, e in zip(freqs, expected)]

            # Score by how many steps land on their expected frequency, not by
            # the total error. A single step that the firmware renders wrongly
            # contributes a couple of octaves of error, which is enough to make
            # the correct alignment score worse than a wrong one -- exactly what
            # happened when the despiker was mangling the 5 kHz step. Counting
            # matches is unaffected by one bad step, and leaves it visible in
            # the output instead of hiding it behind a bad alignment.
            matches = sum(1 for e in errs if e < 0.15)
            key = (-matches, sum(errs))
            if best is None or key < best[0]:
                best = (key, off, rot, segs, freqs, sum(errs))

    if best is None:
        print("capture too short — need at least "
              f"{nsteps * hold_secs + 2:.0f}s after warmup")
        return

    _key, best_off, rot, segs, freqs, err = best

    # Matching on frequency pins down which step we are on, but it cannot pin
    # down where inside the step the window starts: if every window overlaps
    # the next tone by the same fraction, the sequence of dominant frequencies
    # still comes out right. That residual offset leaks the neighbouring tone
    # into every segment, which showed up as identical spurious peaks at the
    # same position in every step. Refine by maximising tonal purity -- the
    # share of each segment's energy sitting at its own frequency, which is
    # highest exactly when no boundary is enclosed.
    def best_rotation(freqs_):
        best_r, best_k = 0, None
        for r in range(nsteps):
            exp = INJECT_SWEEP_HZ[r:] + INJECT_SWEEP_HZ[:r]
            errs = [abs(np.log2(max(m, 1.0) / e)) for m, e in zip(freqs_, exp)]
            key = (-sum(1 for e in errs if e < 0.15), sum(errs))
            if best_k is None or key < best_k:
                best_k, best_r = key, r
        return best_r

    def purity_at(off):
        segs_ = segments(off)
        if segs_ is None:
            return None, None
        r = best_rotation([dominant_hz(s_) for s_ in segs_])
        total = 0.0
        for k, seg in enumerate(segs_):
            f0 = INJECT_SWEEP_HZ[(r + k) % nsteps]
            spec = np.abs(np.fft.rfft(seg * np.hanning(seg.size))) ** 2
            fq = np.fft.rfftfreq(seg.size, 1.0 / rate)
            band = spec[(fq > f0 - 30) & (fq < f0 + 30)].sum()
            tot = spec.sum()
            total += band / tot if tot > 0 else 0.0
        return total / nsteps, segs_

    # Sweep the whole hold period: the boundary can be anywhere in it, and an
    # earlier version only looked at +/- half a period around the coarse hit,
    # which missed offsets in the upper half entirely. Re-derive the rotation
    # at each candidate so offset and rotation stay consistent.
    fine_best = None
    for cand in range(0, min(hold, margin) + 1, max(hold // 64, 1)):
        score, segs_ = purity_at(cand)
        if score is None:
            continue
        if fine_best is None or score > fine_best[0]:
            fine_best = (score, cand, segs_)

    purity_score, best_off, segs = fine_best
    freqs = [dominant_hz(s_) for s_ in segs]
    rot = best_rotation(freqs)
    print(f"(tonal purity {purity_score * 100:.1f} %)")

    # Undo the rotation so segment k corresponds to INJECT_SWEEP_HZ[k].
    order = [(rot + k) % nsteps for k in range(nsteps)]
    lv = [0.0] * nsteps
    measured = [0.0] * nsteps
    for k, seg in enumerate(segs):
        lv[order[k]] = level(seg)
        measured[order[k]] = freqs[k]

    ref = max(lv) if lv else 0.0
    mean_err = err / nsteps
    print(f"(aligned at +{best_off / rate:.2f}s, rotation {rot}; "
          f"mean frequency error {mean_err:.3f} octaves)")
    bad = sum(1 for f, m in zip(INJECT_SWEEP_HZ, measured)
              if abs(np.log2(max(m, 1.0) / f)) > 0.15)
    if bad > nsteps // 3:
        print("  WARNING: most segments do not match the expected frequencies "
              "— is the firmware really built with PDM_TEST_SIGNAL=2?")
    elif bad:
        print(f"  WARNING: {bad} step(s) came back at the wrong frequency — the "
              "DSP chain is altering the tone, not just its level")
    print("0 dB = loudest step\n")

    for f, v, m in zip(INJECT_SWEEP_HZ, lv, measured):
        if abs(np.log2(max(m, 1.0) / f)) > 0.15:
            print(f"  {f:5d} Hz  -- measured {m:.0f} Hz, skipping")
            continue
        rel = 20 * np.log10(max(v, 1.0) / max(ref, 1.0))
        bar = "█" * max(0, int(40 + rel))
        print(f"  {f:5d} Hz  {rel:6.1f} dB  {bar}")

    def at(f):
        return 20 * np.log10(max(lv[INJECT_SWEEP_HZ.index(f)], 1.0) / max(ref, 1.0))

    print()
    print(f"50 Hz  vs 1.2 kHz : {at(50) - at(1200):6.1f} dB   (high-pass depth)")
    print(f"7 kHz  vs 1.2 kHz : {at(7000) - at(1200):6.1f} dB   (top-end rolloff)")

    if at(50) - at(1200) > -6:
        print("  WARNING: high-pass barely attenuating — check PDM_HPF_STAGES")
    if at(7000) - at(1200) < -10:
        print("  WARNING: strong top-end rolloff — PDM_LPF_ENABLE is probably "
              "still set")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav")
    ap.add_argument("--tone", type=float, default=None,
                    help="frequency in Hz of a reference sine being played "
                         "into the microphone; enables THD/THD+N")
    ap.add_argument("--sweep", action="store_true",
                    help="capture was made with firmware PDM_TEST_SIGNAL=2 "
                         "(injected stepped sweep); report frequency response")
    args = ap.parse_args()

    x, rate = load(args.wav)
    print(f"{args.wav}: {x.size} samples, {rate} Hz, {x.size / rate:.2f} s")

    if x.size == 0:
        sys.exit("empty capture")

    peak = report_levels(x)
    report_clipping(x)
    report_glitches(x, rate)
    report_spectrum(x, rate)
    if args.tone:
        report_tone(x, rate, args.tone)
    if args.sweep:
        report_sweep(x, rate)

    section("Verdict")
    if peak < 500:
        print("Capture is essentially silent — fix signal path before judging "
              "quality.")
    else:
        print("Compare two takes with the same script to judge a change; the "
              "absolute numbers matter less than the difference between runs.")


if __name__ == "__main__":
    main()
