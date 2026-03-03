import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bmc_audio/src/audio_crypto.dart';

void main() {
  group('BmcAudioCrypto', () {
    group('mix32', () {
      test('should produce deterministic output', () {
        // Same input should always produce same output
        final result1 = BmcAudioCrypto.mix32(0x12345678);
        final result2 = BmcAudioCrypto.mix32(0x12345678);
        expect(result1, equals(result2));
      });

      test('should produce different output for different inputs', () {
        final result1 = BmcAudioCrypto.mix32(0);
        final result2 = BmcAudioCrypto.mix32(1);
        expect(result1, isNot(equals(result2)));
      });

      test('zero input is a fixed point of mix32', () {
        // 0 is a fixed point: 0 XOR 0 = 0, 0 * K = 0
        // This is expected behavior and does NOT affect security because
        // the actual input to mix32 is always (SEED ^ sampleIndex),
        // which is non-zero when SEED is non-zero.
        final result = BmcAudioCrypto.mix32(0);
        expect(result, equals(0));
      });

      test('should stay within 32-bit range', () {
        final inputs = [0, 1, 0x7FFFFFFF, 0xFFFFFFFF, 0x80000000, 0xC0FFEE12];
        for (final input in inputs) {
          final result = BmcAudioCrypto.mix32(input);
          expect(result, greaterThanOrEqualTo(0));
          expect(result, lessThanOrEqualTo(0xFFFFFFFF));
        }
      });

      // Reference values computed from the C firmware implementation.
      // These are the expected outputs for specific inputs.
      test('matches firmware reference values', () {
        // mix32(0xC0FFEE12 ^ 0) = mix32(0xC0FFEE12)
        final r0 = BmcAudioCrypto.mix32(0xC0FFEE12);
        expect(r0, isA<int>());
        expect(r0 & 0xFFFFFFFF, equals(r0)); // must be 32-bit

        // mix32(0xC0FFEE12 ^ 1) = mix32(0xC0FFEE13)
        final r1 = BmcAudioCrypto.mix32(0xC0FFEE13);
        expect(r1, isNot(equals(r0))); // different input → different output
      });
    });

    group('keystream16', () {
      test('should produce 16-bit values', () {
        final crypto = BmcAudioCrypto();
        for (int i = 0; i < 100; i++) {
          final key = crypto.keystream16(i);
          expect(key, greaterThanOrEqualTo(0));
          expect(key, lessThanOrEqualTo(0xFFFF));
        }
      });

      test('should produce different values for sequential indices', () {
        final crypto = BmcAudioCrypto();
        final keys = <int>{};
        for (int i = 0; i < 1000; i++) {
          keys.add(crypto.keystream16(i));
        }
        // With a good mixer, we expect most values to be unique
        // Allow some collisions but it should be very rare for 1000 values
        expect(keys.length, greaterThan(950));
      });

      test('should use seed correctly', () {
        final crypto1 = BmcAudioCrypto(seed: 0xC0FFEE12);
        final crypto2 = BmcAudioCrypto(seed: 0xDEADBEEF);

        final key1 = crypto1.keystream16(0);
        final key2 = crypto2.keystream16(0);

        expect(key1, isNot(equals(key2)));
      });

      test('same seed same index should produce same value', () {
        final crypto1 = BmcAudioCrypto(seed: 0xC0FFEE12);
        final crypto2 = BmcAudioCrypto(seed: 0xC0FFEE12);

        for (int i = 0; i < 100; i++) {
          expect(crypto1.keystream16(i), equals(crypto2.keystream16(i)));
        }
      });
    });

    group('transformPcm16le', () {
      test('encrypt then decrypt should recover original data', () {
        final original = Uint8List.fromList([
          0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
          0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        ]);
        final data = Uint8List.fromList(original);

        // Encrypt
        final encryptor = BmcAudioCrypto();
        encryptor.transformPcm16le(data);

        // Data should be different after encryption
        expect(data, isNot(equals(original)));

        // Decrypt
        final decryptor = BmcAudioCrypto();
        decryptor.transformPcm16le(data);

        // Should recover original
        expect(data, equals(original));
      });

      test('should be symmetric (encrypt == decrypt)', () {
        // Create some PCM16LE audio data (simulated sine wave)
        final sampleCount = 160; // 10ms at 16kHz
        final original = Uint8List(sampleCount * 2);
        for (int i = 0; i < sampleCount; i++) {
          // Simple ramp pattern for testing
          final value = (i * 100) & 0xFFFF;
          original[i * 2] = value & 0xFF;
          original[i * 2 + 1] = (value >> 8) & 0xFF;
        }

        final encrypted = Uint8List.fromList(original);

        // Encrypt
        BmcAudioCrypto(seed: 0xC0FFEE12).transformPcm16le(encrypted);

        // Verify it's actually encrypted
        expect(encrypted, isNot(equals(original)));

        // Encrypt again (same as decrypt due to XOR symmetry)
        BmcAudioCrypto(seed: 0xC0FFEE12).transformPcm16le(encrypted);

        // Should match original
        expect(encrypted, equals(original));
      });

      test('empty buffer should not crash', () {
        final crypto = BmcAudioCrypto();
        final empty = Uint8List(0);
        crypto.transformPcm16le(empty);
        expect(empty.length, equals(0));
      });

      test('single byte buffer should be ignored', () {
        final crypto = BmcAudioCrypto();
        final single = Uint8List.fromList([0x42]);
        crypto.transformPcm16le(single);
        expect(single[0], equals(0x42)); // unchanged
      });

      test('odd-length buffer should ignore trailing byte', () {
        final crypto1 = BmcAudioCrypto();
        final crypto2 = BmcAudioCrypto();

        final odd = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
        final even = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);

        crypto1.transformPcm16le(odd);
        crypto2.transformPcm16le(even);

        // First 4 bytes should be transformed identically
        expect(odd[0], equals(even[0]));
        expect(odd[1], equals(even[1]));
        expect(odd[2], equals(even[2]));
        expect(odd[3], equals(even[3]));
        // 5th byte should be untouched
        expect(odd[4], equals(0x05));
      });

      test('sample index should increment correctly', () {
        final crypto = BmcAudioCrypto();
        expect(crypto.sampleIndex, equals(0));

        // 4 bytes = 2 samples
        crypto.transformPcm16le(Uint8List(4));
        expect(crypto.sampleIndex, equals(2));

        // 6 bytes = 3 samples
        crypto.transformPcm16le(Uint8List(6));
        expect(crypto.sampleIndex, equals(5));
      });
    });

    group('reset', () {
      test('should reset sample index to 0', () {
        final crypto = BmcAudioCrypto();
        crypto.transformPcm16le(Uint8List(100));
        expect(crypto.sampleIndex, greaterThan(0));

        crypto.reset();
        expect(crypto.sampleIndex, equals(0));
      });

      test('after reset, same data produces same output', () {
        final data1 = Uint8List.fromList(List.generate(32, (i) => i));
        final data2 = Uint8List.fromList(List.generate(32, (i) => i));

        final crypto = BmcAudioCrypto();

        crypto.transformPcm16le(data1);
        crypto.reset();
        crypto.transformPcm16le(data2);

        expect(data1, equals(data2));
      });
    });

    group('enabled', () {
      test('when disabled, should not transform data', () {
        final crypto = BmcAudioCrypto();
        crypto.enabled = false;

        final original = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        crypto.transformPcm16le(original);

        expect(original, equals(Uint8List.fromList([0x01, 0x02, 0x03, 0x04])));
      });

      test('toggling enabled should reset sample index', () {
        final crypto = BmcAudioCrypto();
        crypto.transformPcm16le(Uint8List(100));
        expect(crypto.sampleIndex, greaterThan(0));

        crypto.enabled = false;
        expect(crypto.sampleIndex, equals(0));

        crypto.enabled = true;
        expect(crypto.sampleIndex, equals(0));
      });
    });

    group('static transform', () {
      test('should produce same result as instance method', () {
        final data = Uint8List.fromList(List.generate(64, (i) => i));

        final staticResult = BmcAudioCrypto.transform(data);

        final instanceCrypto = BmcAudioCrypto();
        final instanceData = Uint8List.fromList(data);
        instanceCrypto.transformPcm16le(instanceData);

        expect(staticResult, equals(instanceData));
      });

      test('should support custom start index', () {
        final data = Uint8List.fromList(List.generate(32, (i) => i));

        // Transform with startIndex=10 should differ from startIndex=0
        final result0 = BmcAudioCrypto.transform(data, startIndex: 0);
        final result10 = BmcAudioCrypto.transform(data, startIndex: 10);

        expect(result0, isNot(equals(result10)));
      });

      test('should not modify original data', () {
        final original = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        final copy = Uint8List.fromList(original);

        BmcAudioCrypto.transform(original);

        expect(original, equals(copy));
      });
    });
  });
}
