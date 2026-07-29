import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bmc_audio/bmc_audio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a smooth, audio-like PCM16LE buffer.
///
/// Real speech has strong adjacent-sample correlation; a sum of low-frequency
/// sinusoids reproduces that property, which is what the offset search keys on.
Uint8List makeAudio(int samples, {int seed = 7}) {
  final rnd = math.Random(seed);
  final phase = rnd.nextDouble() * math.pi;
  final out = Uint8List(samples * 2);
  final view = ByteData.view(out.buffer);

  for (int i = 0; i < samples; i++) {
    final t = i / 16000.0;
    final v = 8000 * math.sin(2 * math.pi * 220 * t + phase) +
        3000 * math.sin(2 * math.pi * 440 * t) +
        1200 * math.sin(2 * math.pi * 900 * t);
    view.setInt16(i * 2, v.round().clamp(-32768, 32767), Endian.little);
  }
  return out;
}

/// Encrypt exactly the way the firmware does, from a given keystream index.
Uint8List encryptFrom(Uint8List plain, int startIndex) =>
    BmcAudioCrypto.transform(plain, startIndex: startIndex);

void main() {
  group('searchOffset', () {
    // The endpoint is asynchronous, so packets carry 15, 16 or 17 samples and
    // the cumulative offset is not a multiple of anything in particular. The
    // old grid search only probed multiples of 16 and would miss these.
    for (final offset in [0, 1, 15, 17, 133, 1021, 4097]) {
      test('recovers offset $offset', () {
        final plain = makeAudio(6000);
        final cipher = encryptFrom(plain, offset);

        final (found, _) = BmcAudioCrypto.searchOffset(cipher, maxOffset: 8000);

        expect(found, offset);
      });
    }

    test('recovered offset decrypts back to the original samples', () {
      const offset = 733;
      final plain = makeAudio(6000);
      final cipher = encryptFrom(plain, offset);

      final (found, _) = BmcAudioCrypto.searchOffset(cipher, maxOffset: 8000);
      final decrypted = BmcAudioCrypto.transform(cipher, startIndex: found);

      expect(decrypted, plain);
    });

    test('locks onto digital silence, where correlation is undefined', () {
      const offset = 291;
      final silence = Uint8List(4000 * 2);
      final cipher = encryptFrom(silence, offset);

      final (found, _) = BmcAudioCrypto.searchOffset(cipher, maxOffset: 8000);

      expect(found, offset);
      expect(BmcAudioCrypto.transform(cipher, startIndex: found), silence);
    });
  });

  group('searchOffsetNear', () {
    test('recovers the shift left by a dropped 16-sample packet', () {
      // The device kept counting through the samples that never arrived, so
      // the host's next byte belongs 16 samples further along the keystream
      // than it believes.
      const believed = 2000;
      const actual = believed + 16;

      final plain = makeAudio(6000);
      final cipher = encryptFrom(plain, actual);

      final (found, _) = BmcAudioCrypto.searchOffsetNear(
        cipher,
        center: believed,
        radius: 512,
      );

      expect(found, actual);
    });

    test('recovers a multi-packet burst loss', () {
      const believed = 5000;
      const actual = believed + 16 * 23;

      final plain = makeAudio(6000);
      final cipher = encryptFrom(plain, actual);

      final (found, _) = BmcAudioCrypto.searchOffsetNear(
        cipher,
        center: believed,
        radius: 512,
      );

      expect(found, actual);
    });

    test('does not invent a lock when the true offset is out of range', () {
      // Beyond the search radius there is no correct answer; whatever comes
      // back must still look like noise so the caller escalates to a full
      // search instead of trusting it.
      const believed = 1000;
      const actual = believed + 5000;

      final plain = makeAudio(6000);
      final cipher = encryptFrom(plain, actual);

      final (found, _) = BmcAudioCrypto.searchOffsetNear(
        cipher,
        center: believed,
        radius: 512,
      );

      final decrypted = BmcAudioCrypto.transform(cipher, startIndex: found);
      expect(BmcAudioCrypto.meanAdjacentDiff(decrypted), greaterThan(12000));
    });
  });

  group('recovery strategies used by the decoder', () {
    /// Mirrors BmcAudioDecoder._locksCleanly.
    bool locksCleanly(Uint8List cipher, int offset) =>
        BmcAudioCrypto.meanAdjacentDiff(
            BmcAudioCrypto.transform(cipher, startIndex: offset)) <=
        12000;

    test('a one-second stall is found by widening the radius, not by an '
        'absolute search', () {
      // Ten minutes into a stream the true index is in the millions. An
      // absolute 0..16000 search — which is what the first version of the
      // fallback did — cannot possibly reach it.
      const believed = 9600000;
      const actual = believed + 16000; // 1 s of audio lost

      final plain = makeAudio(6000);
      final cipher = encryptFrom(plain, actual);

      final (narrow, _) =
          BmcAudioCrypto.searchOffsetNear(cipher, center: believed, radius: 512);
      expect(locksCleanly(cipher, narrow), isFalse,
          reason: 'the narrow radius must not reach this far');

      final (absolute, _) =
          BmcAudioCrypto.searchOffset(cipher, maxOffset: 16000);
      expect(locksCleanly(cipher, absolute), isFalse,
          reason: 'an absolute search looks in the wrong range entirely');

      final (wide, _) = BmcAudioCrypto.searchOffsetNear(cipher,
          center: believed, radius: 16000);
      expect(wide, actual);
      expect(locksCleanly(cipher, wide), isTrue);
    });

    test('a device restart is found by the absolute search', () {
      // Firmware calls AudioCrypto_Reset() when it re-primes the stream, so
      // its keystream goes back near zero however long we had been streaming.
      const believed = 9600000;
      const actual = 32; // two priming packets

      final plain = makeAudio(6000);
      final cipher = encryptFrom(plain, actual);

      final (wide, _) = BmcAudioCrypto.searchOffsetNear(cipher,
          center: believed, radius: 16000);
      expect(locksCleanly(cipher, wide), isFalse,
          reason: 'searching around the stale index cannot find zero');

      final (absolute, _) =
          BmcAudioCrypto.searchOffset(cipher, maxOffset: 16000);
      expect(absolute, actual);
      expect(locksCleanly(cipher, absolute), isTrue);
    });

    test('pure noise locks nowhere, so the decoder reports failure', () {
      // Nothing in the ladder should claim success on data that is not our
      // stream at all.
      final rnd = math.Random(99);
      final noise = Uint8List.fromList(
          List<int>.generate(6000 * 2, (_) => rnd.nextInt(256)));

      for (final offset in [
        BmcAudioCrypto.searchOffsetNear(noise, center: 5000, radius: 512).$1,
        BmcAudioCrypto.searchOffsetNear(noise, center: 5000, radius: 16000).$1,
        BmcAudioCrypto.searchOffset(noise, maxOffset: 16000).$1,
      ]) {
        expect(locksCleanly(noise, offset), isFalse);
      }
    });
  });

  group('meanAdjacentDiff', () {
    test('separates correct decryption from a wrong offset by a wide margin',
        () {
      final plain = makeAudio(4000);
      final cipher = encryptFrom(plain, 500);

      final right = BmcAudioCrypto.transform(cipher, startIndex: 500);
      final wrong = BmcAudioCrypto.transform(cipher, startIndex: 501);

      // The decoder's desync detector sits at 12000 between these two.
      expect(BmcAudioCrypto.meanAdjacentDiff(right), lessThan(6000));
      expect(BmcAudioCrypto.meanAdjacentDiff(wrong), greaterThan(12000));
    });
  });
}
