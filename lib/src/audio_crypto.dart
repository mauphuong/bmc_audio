import 'dart:math' as math;
import 'dart:typed_data';

/// BMC Audio Crypto — Pure Dart port of firmware `audio_crypto.c`.
///
/// Provides reversible XOR-based PCM16LE stream transform using a
/// deterministic per-sample keystream derived from [mix32].
///
/// The transform is symmetric: applying it twice recovers the original data.
/// This matches the firmware implementation exactly.
class BmcAudioCrypto {
  /// Default encryption seed matching firmware `AUDIO_USB_ENCRYPT_SEED`.
  static const int defaultSeed = 0xC0FFEE12;

  /// The seed used for keystream generation.
  final int seed;

  /// Current sample index (increments per 16-bit sample).
  int _sampleIndex = 0;

  /// Whether encryption/decryption is enabled.
  bool _enabled = true;

  /// Create a crypto instance with the given [seed].
  ///
  /// The seed must match the firmware's `AUDIO_USB_ENCRYPT_SEED` value
  /// for correct decryption.
  BmcAudioCrypto({this.seed = defaultSeed});

  /// Current sample index position in the keystream.
  // ignore: unnecessary_getters_setters
  int get sampleIndex => _sampleIndex;

  /// Set the sample index directly (used by offset search).
  // ignore: unnecessary_getters_setters
  set sampleIndex(int value) => _sampleIndex = value;

  /// Whether the transform is currently enabled.
  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled != value) {
      _enabled = value;
      // Reset keystream position to keep alignment deterministic,
      // matching firmware AudioCrypto_SetEnabled() behavior.
      reset();
    }
  }

  /// Reset the sample index to 0.
  ///
  /// Must be called when a new audio stream starts to align with
  /// the firmware's `AudioCrypto_Reset()` call on stream prime.
  void reset() {
    _sampleIndex = 0;
  }

  /// 32-bit integer mixer (deterministic, fast).
  ///
  /// Port of firmware `mix32()`. Uses unsigned 32-bit arithmetic
  /// via masking with `0xFFFFFFFF`.
  ///
  /// ```c
  /// static inline uint32_t mix32(uint32_t x) {
  ///     x ^= x >> 16;
  ///     x *= 0x7FEB352DU;
  ///     x ^= x >> 15;
  ///     x *= 0x846CA68BU;
  ///     x ^= x >> 16;
  ///     return x;
  /// }
  /// ```
  static int mix32(int x) {
    // Ensure unsigned 32-bit
    x = x & 0xFFFFFFFF;

    x ^= (x >> 16) & 0xFFFF;
    x = x & 0xFFFFFFFF;

    x = _mul32(x, 0x7FEB352D);

    x ^= (x >> 15) & 0x1FFFF;
    x = x & 0xFFFFFFFF;

    x = _mul32(x, 0x846CA68B);

    x ^= (x >> 16) & 0xFFFF;
    x = x & 0xFFFFFFFF;

    return x;
  }

  /// Generate a 16-bit keystream value for the given [sampleIndex].
  ///
  /// Port of firmware `keystream16()`:
  /// ```c
  /// static inline uint16_t keystream16(uint32_t sampleIndex) {
  ///     uint32_t x = (uint32_t)AUDIO_USB_ENCRYPT_SEED ^ sampleIndex;
  ///     return (uint16_t)mix32(x);
  /// }
  /// ```
  int keystream16(int sampleIndex) {
    final x = (seed ^ sampleIndex) & 0xFFFFFFFF;
    return mix32(x) & 0xFFFF;
  }

  /// Transform (encrypt or decrypt) a buffer of 16-bit LE PCM samples in-place.
  ///
  /// Port of firmware `AudioCrypto_TransformPcm16le()`.
  /// The buffer length must be in bytes. Odd trailing bytes are ignored.
  ///
  /// Returns the same [buffer] for convenience.
  Uint8List transformPcm16le(Uint8List buffer) {
    if (!_enabled || buffer.length < 2) {
      return buffer;
    }

    final sampleCount = buffer.length ~/ 2;

    for (int i = 0; i < sampleCount; i++) {
      final key = keystream16(_sampleIndex++);

      // XOR each 16-bit LE sample with keystream
      final offset = i * 2;
      buffer[offset] ^= key & 0xFF;
      buffer[offset + 1] ^= (key >> 8) & 0xFF;
    }

    return buffer;
  }

  /// Static one-shot decrypt/encrypt utility.
  ///
  /// Creates a temporary [BmcAudioCrypto] instance, optionally starting
  /// from [startIndex], and transforms the data.
  ///
  /// Returns a new [Uint8List] with the transformed data (original untouched).
  static Uint8List transform(
    Uint8List data, {
    int seed = defaultSeed,
    int startIndex = 0,
  }) {
    final crypto = BmcAudioCrypto(seed: seed);
    crypto._sampleIndex = startIndex;
    final result = Uint8List.fromList(data);
    crypto.transformPcm16le(result);
    return result;
  }

  /// Unsigned 32-bit multiplication.
  ///
  /// Dart's int is 64-bit, so we need to truncate to 32 bits after multiply.
  static int _mul32(int a, int b) {
    // Split into 16-bit halves to avoid 64-bit overflow issues
    final aLo = a & 0xFFFF;
    final aHi = (a >> 16) & 0xFFFF;
    final bLo = b & 0xFFFF;
    final bHi = (b >> 16) & 0xFFFF;

    // Compute partial products (only low 32 bits matter)
    int result = aLo * bLo;
    result += ((aHi * bLo) & 0xFFFF) << 16;
    result += ((aLo * bHi) & 0xFFFF) << 16;

    return result & 0xFFFFFFFF;
  }

  // ══════════════════════════════════════════════════════════════════
  // Offset Search (ported from Python uac_capture_decrypt.py)
  // ══════════════════════════════════════════════════════════════════

  /// Score how "audio-like" a PCM16LE buffer is.
  ///
  /// Real audio has high adjacent-sample correlation (smooth waveform).
  /// Encrypted/random noise has near-zero correlation.
  /// Returns 0.0 (noise) to 1.0 (clean audio).
  static double scoreAudioLike(Uint8List pcm16le) {
    final sampleCount = pcm16le.length ~/ 2;
    if (sampleCount < 64) return 0.0;

    // Parse int16 samples
    final samples = List<double>.generate(sampleCount, (i) {
      int s = pcm16le[i * 2] | (pcm16le[i * 2 + 1] << 8);
      if (s > 32767) s -= 65536;
      return s.toDouble();
    });

    // Compute mean
    double mean = 0;
    for (final s in samples) {
      mean += s;
    }
    mean /= sampleCount;

    // Subtract mean and compute adjacent-sample correlation
    double sumAB = 0, sumAA = 0, sumBB = 0;
    for (int i = 0; i < sampleCount - 1; i++) {
      final a = samples[i] - mean;
      final b = samples[i + 1] - mean;
      sumAB += a * b;
      sumAA += a * a;
      sumBB += b * b;
    }

    final denom = (sumAA * sumBB);
    if (denom < 1e-12) return 0.0;

    final corr = sumAB / math.sqrt(denom);
    return corr.abs();
  }

  /// Mean absolute difference between adjacent 16-bit samples.
  ///
  /// This is the metric used to align the keystream, because it works for
  /// **both** real audio and digital silence:
  /// - Correctly-decrypted audio is smooth → small adjacent difference.
  /// - Correctly-decrypted silence is all zeros → adjacent difference ~0.
  /// - A wrong keystream offset yields pseudo-random noise → huge difference.
  ///
  /// (Adjacent-sample correlation via [scoreAudioLike] cannot distinguish the
  /// true offset during silence, where every offset scores ~0.)
  static double meanAdjacentDiff(Uint8List pcm16le) {
    final sampleCount = pcm16le.length ~/ 2;
    if (sampleCount < 2) return 0.0;
    int prev = pcm16le[0] | (pcm16le[1] << 8);
    if (prev > 32767) prev -= 65536;
    double sum = 0;
    for (int i = 1; i < sampleCount; i++) {
      int s = pcm16le[i * 2] | (pcm16le[i * 2 + 1] << 8);
      if (s > 32767) s -= 65536;
      sum += (s - prev).abs();
      prev = s;
    }
    return sum / (sampleCount - 1);
  }

  /// Number of samples used by the first-pass probe in [searchOffset].
  ///
  /// The scoring surface is effectively a delta function: at any offset other
  /// than the exact one, every sample decrypts to a different pseudo-random
  /// value, so [meanAdjacentDiff] jumps to the ~21800 expected of uniform
  /// noise. A short probe therefore separates the true offset from every other
  /// candidate just as decisively as a long one, at a fraction of the cost.
  static const int _probeSamples = 96;

  /// How many probe candidates get re-scored against a long window.
  static const int _probeCandidates = 8;

  /// Samples used to confirm a candidate found by the probe pass.
  static const int _verifySamples = 2048;

  /// Score a single candidate offset over [windowSamples] samples.
  static double _scoreOffset(
    Uint8List cipher,
    int seed,
    int offset,
    int windowSamples,
  ) {
    final available = cipher.length ~/ 2;
    final n = windowSamples > available ? available : windowSamples;
    if (n < 2) return double.infinity;

    final crypto = BmcAudioCrypto(seed: seed);
    crypto._sampleIndex = offset;
    final test = Uint8List.sublistView(cipher, 0, n * 2);
    final work = Uint8List.fromList(test);
    crypto.transformPcm16le(work);
    return meanAdjacentDiff(work);
  }

  /// Scan every offset in `[start, end]` and return the best candidates.
  ///
  /// Returns offsets sorted by ascending [meanAdjacentDiff], best first.
  static List<int> _scanRange(
    Uint8List cipher,
    int seed,
    int start,
    int end,
    int keep,
  ) {
    final scored = <({int offset, double diff})>[];

    for (int off = start; off <= end; off++) {
      final diff = _scoreOffset(cipher, seed, off, _probeSamples);
      scored.add((offset: off, diff: diff));
    }

    scored.sort((a, b) => a.diff.compareTo(b.diff));
    return scored.take(keep).map((e) => e.offset).toList();
  }

  /// Pick the candidate with the lowest long-window score.
  static (int, double) _verifyCandidates(
    Uint8List cipher,
    int seed,
    List<int> candidates,
  ) {
    int bestOffset = candidates.isEmpty ? 0 : candidates.first;
    double bestDiff = double.infinity;

    for (final off in candidates) {
      final diff = _scoreOffset(cipher, seed, off, _verifySamples);
      if (diff < bestDiff) {
        bestDiff = diff;
        bestOffset = off;
      }
    }

    // Report correlation at the chosen offset for logging.
    final available = cipher.length ~/ 2;
    final n = _verifySamples > available ? available : _verifySamples;
    final crypto = BmcAudioCrypto(seed: seed);
    crypto._sampleIndex = bestOffset;
    final chosen = Uint8List.fromList(Uint8List.sublistView(cipher, 0, n * 2));
    crypto.transformPcm16le(chosen);
    return (bestOffset, scoreAudioLike(chosen));
  }

  /// Search for the best keystream offset.
  ///
  /// When capturing via USB-direct (Android/Linux) or the OS audio driver
  /// (Windows/macOS), the firmware may have streamed some samples before our
  /// app starts reading. This finds the correct starting `sampleIndex`.
  ///
  /// Selection minimizes [meanAdjacentDiff], which is robust to silence:
  /// correctly-decrypted silence is all zeros (difference ~0) whereas a wrong
  /// offset yields pseudo-random noise (difference ~21800). Adjacent-sample
  /// correlation cannot make that distinction during silence.
  ///
  /// This used to do a coarse pass stepping 16 samples at a time, on the
  /// assumption that every USB packet carries exactly 16 samples so the true
  /// offset must be a multiple of 16. That assumption no longer holds: the
  /// firmware's audio endpoint is asynchronous and varies the payload between
  /// 15 and 17 samples to track the host clock, so the cumulative offset can
  /// be any integer. Since the scoring surface has no gradient to follow, a
  /// grid that misses the true offset finds nothing at all — hence the
  /// exhaustive probe pass below.
  ///
  /// [cipherPcm16le] — first chunk of captured (encrypted) audio bytes.
  /// [maxOffset] — maximum offset to search (default: 16000 = 1 second at 16kHz).
  ///
  /// Returns `(bestOffset, confidence)` where confidence is the
  /// adjacent-sample correlation ([scoreAudioLike]) at the chosen offset
  /// (informational: high for audio, ~0 for silence — both still valid locks).
  static (int, double) searchOffset(
    Uint8List cipherPcm16le, {
    int seed = defaultSeed,
    int maxOffset = 16000,
  }) {
    final candidates =
        _scanRange(cipherPcm16le, seed, 0, maxOffset, _probeCandidates);
    return _verifyCandidates(cipherPcm16le, seed, candidates);
  }

  /// Re-acquire the keystream offset in a narrow window around [center].
  ///
  /// Used to recover from a mid-stream desynchronisation. A dropped
  /// isochronous packet shifts the alignment by only a handful of samples, so
  /// searching +/- [radius] around the expected index converges in a fraction
  /// of the time a full search would take.
  ///
  /// Returns `(bestOffset, confidence)`.
  static (int, double) searchOffsetNear(
    Uint8List cipherPcm16le, {
    required int center,
    int seed = defaultSeed,
    int radius = 512,
  }) {
    final start = (center - radius) < 0 ? 0 : (center - radius);
    final end = center + radius;
    final candidates =
        _scanRange(cipherPcm16le, seed, start, end, _probeCandidates);
    return _verifyCandidates(cipherPcm16le, seed, candidates);
  }
}
