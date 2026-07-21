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

  /// Search for the best keystream offset.
  ///
  /// When capturing via USB-direct (Android/Linux) or the OS audio driver
  /// (Windows/macOS), the firmware may have streamed some samples before our
  /// app starts reading. This finds the correct starting `sampleIndex`.
  ///
  /// Selection minimizes [meanAdjacentDiff] (robust to silence). The USB audio
  /// packet is 16 samples, so the true offset is a multiple of 16 — the coarse
  /// step of 16 lands on it exactly; the fine pass covers any residual jitter.
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
    final sampleCount = cipherPcm16le.length ~/ 2;
    final window = sampleCount > 8192 ? 8192 : sampleCount;
    final windowBytes = window * 2;
    final segment = cipherPcm16le.sublist(0, windowBytes);

    int bestOffset = 0;
    double bestDiff = double.infinity;

    final crypto = BmcAudioCrypto(seed: seed);

    void evaluate(int off) {
      crypto._sampleIndex = off;
      final test = Uint8List.fromList(segment);
      crypto.transformPcm16le(test);
      final diff = meanAdjacentDiff(test);
      if (diff < bestDiff) {
        bestDiff = diff;
        bestOffset = off;
      }
    }

    // Coarse search on the packet grid (16 samples), then refine.
    for (int off = 0; off <= maxOffset; off += 16) {
      evaluate(off);
    }
    final fineStart = (bestOffset - 64).clamp(0, maxOffset);
    final fineEnd = (bestOffset + 64).clamp(0, maxOffset);
    for (int off = fineStart; off <= fineEnd; off++) {
      evaluate(off);
    }

    // Report correlation at the chosen offset for logging.
    crypto._sampleIndex = bestOffset;
    final chosen = Uint8List.fromList(segment);
    crypto.transformPcm16le(chosen);
    return (bestOffset, scoreAudioLike(chosen));
  }
}
