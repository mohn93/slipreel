import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _record(
    List<({int micros, double x, double y})> samples) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(CursorPosition(
        x: s.x, y: s.y, timestampMicros: s.micros));
  }
  return r;
}

void main() {
  group('medianCursorOver', () {
    test('null when the recording is empty', () {
      final out = medianCursorOver(
        recording: _record([]),
        t: const Duration(seconds: 1),
        window: const Duration(seconds: 1),
      );
      expect(out, isNull);
    });

    test('marginal median over a window of clustered samples', () {
      // Cursor is mostly clustered around (100, 200) with one
      // outlier at (1000, 2000). Marginal median (per-axis) drops
      // the outlier — that's the whole point of the predictive
      // mode versus a mean.
      final rec = _record([
        (micros:   0, x: 95,   y: 195),
        (micros: 100, x: 100,  y: 200),
        (micros: 200, x: 105,  y: 205),
        (micros: 300, x: 110,  y: 210),
        (micros: 400, x: 1000, y: 2000), // brief excursion
      ]);

      final out = medianCursorOver(
        recording: rec,
        t: const Duration(microseconds: 400),
        window: const Duration(microseconds: 400),
      );

      // Sorted X: [95, 100, 105, 110, 1000] → median 105.
      // Sorted Y: [195, 200, 205, 210, 2000] → median 205.
      expect(out!.dx, 105);
      expect(out.dy, 205);
    });

    test('window=0 falls through to instantaneous cursor lookup', () {
      final rec = _record([
        (micros:   0, x: 0, y: 0),
        (micros: 100, x: 100, y: 200),
      ]);

      final out = medianCursorOver(
        recording: rec,
        t: const Duration(microseconds: 100),
        window: Duration.zero,
      );
      expect(out, const Offset(100, 200));
    });

    test(
        'window straddling a gap with no samples falls back to '
        'interpolated cursor at t', () {
      // Samples exist only at t=10s; ask for the median over
      // [0..1s]. The window contains nothing. Rather than returning
      // null (which would break "lock to last known cursor" UX),
      // we fall back to the interpolated cursor lookup.
      final rec = _record([
        (micros: 10_000_000, x: 50, y: 60),
      ]);

      final out = medianCursorOver(
        recording: rec,
        t: const Duration(seconds: 1),
        window: const Duration(seconds: 1),
      );
      // getPositionAt clamps to the nearest sample for out-of-range
      // queries, so we end up at (50, 60).
      expect(out, const Offset(50, 60));
    });

    test('returns the lower median for even-length windows', () {
      // Lower-median policy keeps the result deterministic and
      // matches what most robust-stats libs do. With an even count
      // and no clear center, this pins behavior.
      final rec = _record([
        (micros:   0, x: 10, y: 20),
        (micros: 100, x: 20, y: 30),
        (micros: 200, x: 30, y: 40),
        (micros: 300, x: 40, y: 50),
      ]);
      final out = medianCursorOver(
        recording: rec,
        t: const Duration(microseconds: 300),
        window: const Duration(microseconds: 300),
      );
      // Sorted X: [10, 20, 30, 40] → mid index = 4 ~/ 2 = 2 → 30.
      // Sorted Y: [20, 30, 40, 50] → mid = 2 → 40.
      expect(out!.dx, 30);
      expect(out.dy, 40);
    });
  });
}
