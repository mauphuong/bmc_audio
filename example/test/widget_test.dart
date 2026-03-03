import 'package:flutter_test/flutter_test.dart';

import 'package:bmc_audio_example/main.dart';

void main() {
  testWidgets('App renders correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const BmcAudioExampleApp());

    // Verify essential UI elements are present
    expect(find.text('BMC Audio Decoder'), findsOneWidget);
    expect(find.text('Audio Device'), findsOneWidget);
    expect(find.text('Start Capture'), findsOneWidget);
  });
}
