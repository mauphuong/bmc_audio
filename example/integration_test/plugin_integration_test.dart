// BMC Audio integration test.
//
// Tests the BmcAudioCrypto on a real device to verify
// cross-platform correctness.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'dart:typed_data';

import 'package:bmc_audio/bmc_audio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BmcAudioCrypto encrypt-decrypt round-trip',
      (WidgetTester tester) async {
    // Create test PCM data
    final original = Uint8List.fromList(List.generate(64, (i) => i));
    final data = Uint8List.fromList(original);

    // Encrypt
    final encryptor = BmcAudioCrypto();
    encryptor.transformPcm16le(data);
    expect(data, isNot(equals(original)));

    // Decrypt
    final decryptor = BmcAudioCrypto();
    decryptor.transformPcm16le(data);
    expect(data, equals(original));
  });

  testWidgets('BmcAudioDecoder can be instantiated',
      (WidgetTester tester) async {
    final decoder = BmcAudioDecoder();
    expect(decoder.isCapturing, false);
    expect(decoder.state, BmcCaptureState.idle);
    decoder.dispose();
  });
}
