import 'dart:ui';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';

/// Returns the interpolated cursor position at the given time, or null if
/// the recording is empty.
///
/// This wraps [CursorRecording.getPositionAt] in a typed [Duration] API and
/// is the single source of truth for cursor-time lookups across the export
/// compositor and the preview overlay painter.
CursorPosition? cursorAt(CursorRecording recording, Duration t) {
  return recording.getPositionAt(t.inMicroseconds);
}

/// Marginal median (median X, median Y separately) of every recorded
/// cursor sample whose timestamp falls in `[t - window, t]`. Returns
/// `null` when the window contains no samples.
///
/// Used by the predictive follow mode to track the cursor's *dwell
/// location* — the point where the cursor has been spending the most
/// time recently — instead of its instantaneous position. Marginal
/// median is fast (O(n log n) sort), robust to brief excursions, and
/// pairs well with the focal tween's smoothing on top.
Offset? medianCursorOver({
  required CursorRecording recording,
  required Duration t,
  required Duration window,
}) {
  if (window <= Duration.zero) {
    final c = cursorAt(recording, t);
    return c == null ? null : Offset(c.x, c.y);
  }
  final endMicros = t.inMicroseconds;
  final startMicros = endMicros - window.inMicroseconds;
  final all = recording.positions;
  if (all.isEmpty) return null;

  final xs = <double>[];
  final ys = <double>[];
  for (final p in all) {
    final ts = p.timestampMicros;
    if (ts < startMicros) continue;
    if (ts > endMicros) break; // positions list is time-sorted
    xs.add(p.x);
    ys.add(p.y);
  }
  if (xs.isEmpty) {
    // Window straddles a gap with no recorded samples; fall back to
    // the interpolated cursor at `t` so the camera doesn't lock to
    // some stale value.
    final c = cursorAt(recording, t);
    return c == null ? null : Offset(c.x, c.y);
  }
  xs.sort();
  ys.sort();
  // Lower median for even-length sequences — deterministic and
  // matches what most "robust statistics" libraries do.
  final mid = xs.length ~/ 2;
  return Offset(xs[mid], ys[mid]);
}

/// Maps a cursor position captured in screen coordinates to the corresponding
/// position inside a video of [videoSize], assuming the captured area filled
/// [screenSize]. Used when the recorded video is a different resolution than
/// the screen the cursor was tracked on (e.g. window-only capture, or scaled
/// export).
Offset screenToVideoSpace({
  required Offset screenPos,
  required Size screenSize,
  required Size videoSize,
}) {
  final scaleX = videoSize.width / screenSize.width;
  final scaleY = videoSize.height / screenSize.height;
  return Offset(screenPos.dx * scaleX, screenPos.dy * scaleY);
}
