/// Picks a representative frame time for a recording's thumbnail:
/// 10% in, floored to 1s, and never past `duration - 200ms`. Very short
/// clips use the midpoint; zero/unknown duration returns zero (first
/// frame).
Duration thumbTimestamp(Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  final cap = duration - const Duration(milliseconds: 200);
  if (cap <= Duration.zero) {
    return Duration(microseconds: duration.inMicroseconds ~/ 2);
  }
  if (duration <= const Duration(milliseconds: 1200)) {
    final mid = Duration(microseconds: duration.inMicroseconds ~/ 2);
    return mid <= cap ? mid : cap;
  }
  final tenth = Duration(milliseconds: duration.inMilliseconds ~/ 10);
  final floored =
      tenth < const Duration(seconds: 1) ? const Duration(seconds: 1) : tenth;
  return floored <= cap ? floored : cap;
}
