// packages/slipreel_engine/lib/export/ffmpeg_filters.dart

/// Seconds with microsecond precision, for ffmpeg `st=`/`d=`/`start=` args.
String ffSeconds(Duration d) => (d.inMicroseconds / 1000000).toStringAsFixed(6);

/// Video PTS rescale for a playback-speed factor (2.0 ⇒ plays 2× faster).
String setptsForSpeed(double speed) => 'setpts=PTS/$speed';

/// ffmpeg's `atempo` only accepts a factor in [0.5, 2.0]; larger/smaller
/// speed changes must be chained. Returns the ordered per-filter factors
/// whose product equals [speed], each within [0.5, 2.0].
List<double> atempoChain(double speed) {
  final factors = <double>[];
  var s = speed;
  while (s > 2.0) {
    factors.add(2.0);
    s /= 2.0;
  }
  while (s < 0.5) {
    factors.add(0.5);
    s /= 0.5;
  }
  factors.add(s);
  return factors;
}

/// `atempo=...,atempo=...` chain implementing [speed] for audio.
String speedAtempo(double speed) =>
    atempoChain(speed).map((f) => 'atempo=$f').join(',');
