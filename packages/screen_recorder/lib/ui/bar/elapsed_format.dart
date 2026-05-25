/// Formats a recording duration as `m:ss` (minutes uncapped, seconds
/// zero-padded). Used by the recording pill timer.
String formatElapsed(Duration d) {
  final totalSeconds = d.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
