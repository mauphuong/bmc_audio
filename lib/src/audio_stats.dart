/// A snapshot of how well a capture session is actually delivering audio.
///
/// The headline number is [lossPercent]. Every way audio can go missing —
/// isochronous packets the transport dropped, windows discarded while the
/// keystream was re-acquired, firmware ring overflows — ends up as samples that
/// never reached the listener, and this counts them all the same way: compare
/// how many samples arrived against how many should have in the elapsed time.
///
/// It is also platform-neutral, which is the point. iOS reads audio over the
/// reliable CCID channel and Android over isochronous, so the two cannot be
/// compared by inspecting their transports; they can be compared by asking each
/// one how much of a second of audio it actually delivered.
class BmcAudioStats {
  /// Wall-clock time since capture started.
  final Duration elapsed;

  /// 16-bit samples actually handed to the listener.
  final int samplesEmitted;

  /// Samples that should have arrived in [elapsed] at the configured rate.
  final int samplesExpected;

  /// Isochronous packets the native layer reported as lost.
  ///
  /// Always zero on a reliable transport (iOS CCID), so a like-for-like
  /// comparison has to use [lossPercent], not this.
  final int droppedPackets;

  /// Times the keystream had to be re-acquired.
  final int resyncCount;

  const BmcAudioStats({
    required this.elapsed,
    required this.samplesEmitted,
    required this.samplesExpected,
    required this.droppedPackets,
    required this.resyncCount,
  });

  /// Percentage of expected audio that never arrived. 0 is perfect.
  ///
  /// Small negative values are possible and harmless: the device clock is not
  /// locked to the host's, so it can legitimately run a few hundred ppm fast.
  double get lossPercent {
    if (samplesExpected <= 0) return 0;
    return (samplesExpected - samplesEmitted) * 100.0 / samplesExpected;
  }

  /// Audio missing from the stream, expressed as time.
  Duration get lostAudio {
    final missing = samplesExpected - samplesEmitted;
    if (missing <= 0 || samplesExpected <= 0) return Duration.zero;
    return Duration(
      microseconds: missing * elapsed.inMicroseconds ~/ samplesExpected,
    );
  }

  /// One-line summary suitable for a log.
  @override
  String toString() =>
      'BmcAudioStats(${elapsed.inSeconds}s: '
      'loss ${lossPercent.toStringAsFixed(2)}% '
      '(${lostAudio.inMilliseconds}ms), '
      'dropped $droppedPackets, resync $resyncCount)';
}
