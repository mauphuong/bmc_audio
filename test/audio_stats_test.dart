import 'package:bmc_audio/bmc_audio.dart';
import 'package:flutter_test/flutter_test.dart';

BmcAudioStats statsFor({
  required int elapsedMs,
  required int samplesEmitted,
  int rate = 16000,
  int dropped = 0,
  int resync = 0,
}) =>
    BmcAudioStats(
      elapsed: Duration(milliseconds: elapsedMs),
      samplesEmitted: samplesEmitted,
      samplesExpected: elapsedMs * rate ~/ 1000,
      droppedPackets: dropped,
      resyncCount: resync,
    );

void main() {
  group('BmcAudioStats', () {
    test('a perfect link reports no loss', () {
      final s = statsFor(elapsedMs: 60000, samplesEmitted: 960000);
      expect(s.lossPercent, 0);
      expect(s.lostAudio, Duration.zero);
    });

    test('quantifies a link delivering 95% of its samples', () {
      final s = statsFor(elapsedMs: 60000, samplesEmitted: 912000);
      expect(s.lossPercent, closeTo(5.0, 0.001));
      expect(s.lostAudio.inMilliseconds, closeTo(3000, 1));
    });

    test('one dropped isochronous packet per second is about 0.1%', () {
      // A packet carries 16 samples at 16 kHz, so 60 packets over a minute.
      final s = statsFor(
        elapsedMs: 60000,
        samplesEmitted: 960000 - 60 * 16,
        dropped: 60,
      );
      expect(s.lossPercent, closeTo(0.1, 0.01));
    });

    test('one re-acquisition costs the 256 ms window it discards', () {
      final s = statsFor(
        elapsedMs: 60000,
        samplesEmitted: 960000 - 4096,
        resync: 1,
      );
      expect(s.lostAudio.inMilliseconds, closeTo(256, 2));
    });

    test('a device clock running fast reads as slightly negative loss', () {
      // The device is not locked to the host clock, so it can legitimately
      // deliver a few hundred ppm more than nominal. That must not be reported
      // as a problem, and must not turn into negative "lost audio".
      final s = statsFor(elapsedMs: 60000, samplesEmitted: 960100);
      expect(s.lossPercent, lessThan(0));
      expect(s.lostAudio, Duration.zero);
    });

    test('is safe before any audio has arrived', () {
      final s = statsFor(elapsedMs: 0, samplesEmitted: 0);
      expect(s.lossPercent, 0);
      expect(s.lostAudio, Duration.zero);
    });

    test('summary line carries the numbers a log reader needs', () {
      final s = statsFor(
        elapsedMs: 60000,
        samplesEmitted: 912000,
        dropped: 12,
        resync: 3,
      );
      final text = s.toString();
      expect(text, contains('60s'));
      expect(text, contains('5.00%'));
      expect(text, contains('dropped 12'));
      expect(text, contains('resync 3'));
    });
  });
}
