import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';

// NOTE: CursorRecording has no `positions:` constructor — positions are
// added one at a time via addPosition(). Adapted from the brief's helper
// (which assumed a `positions:` ctor param) to match the real API; the
// exact pattern used by test/rendering/cursor_motion_controller_test.dart.
CursorRecording _record(List<({int micros, double x, double y})> pts) {
  final r = CursorRecording();
  for (final p in pts) {
    r.addPosition(CursorPosition(
      x: p.x,
      y: p.y,
      timestampMicros: p.micros,
      isClicked: false,
    ));
  }
  return r;
}

void main() {
  const none = CursorPostProcess.none;
  const sigma = Duration(milliseconds: 80);

  group('smoothedCursorAt', () {
    test('sigma zero is the identity (returns cursorAtFiltered)', () {
      final rec = _record([
        (micros: 0, x: 0, y: 0),
        (micros: 100000, x: 100, y: 50),
        (micros: 200000, x: 200, y: 100),
      ]);
      const t = Duration(milliseconds: 150);
      final smoothed = smoothedCursorAt(rec, t, none, Duration.zero);
      final raw = cursorAtFiltered(rec, t, none);
      expect(smoothed!.x, raw!.x);
      expect(smoothed.y, raw.y);
    });

    test('a stationary segment is exact (at-rest identity)', () {
      // Long hold at (300, 200): every tap in the window sees the same
      // point, so the weighted mean IS the point — click landings stay
      // truthful.
      final rec = _record([
        for (var i = 0; i <= 60; i++)
          (micros: i * 16667, x: 300.0, y: 200.0),
      ]);
      final s = smoothedCursorAt(
          rec, const Duration(milliseconds: 500), none, sigma);
      expect(s!.x, closeTo(300.0, 1e-9));
      expect(s.y, closeTo(200.0, 1e-9));
    });

    test('attenuates a 60 Hz-ish zigzag jitter by at least 60 %', () {
      // ±12 px square-wave wiggle around y=100 while x sweeps — the
      // hand-jitter shape the smoother exists to kill.
      final rec = _record([
        for (var i = 0; i <= 120; i++)
          (
            micros: i * 16667,
            x: i * 8.0,
            y: 100.0 + (i.isEven ? 12.0 : -12.0),
          ),
      ]);
      // Peak deviation of the smoothed path from the centerline across
      // the steady middle of the recording.
      var maxDev = 0.0;
      for (var ms = 500; ms <= 1500; ms += 10) {
        final s =
            smoothedCursorAt(rec, Duration(milliseconds: ms), none, sigma)!;
        maxDev = math.max(maxDev, (s.y - 100.0).abs());
      }
      expect(maxDev, lessThan(12.0 * 0.4),
          reason: 'Gaussian window must attenuate alternating-sample '
              'jitter by ≥60% (got peak ${maxDev.toStringAsFixed(2)}px '
              'of a 12px input wiggle)');
    });

    test('rounds a right-angle corner (cuts inside, bounded)', () {
      // Path runs right along y=0 to (500, 0) then straight up. At the
      // corner instant the smoothed point is pulled inside the corner
      // (both arms contribute), but by less than the ±2σ arm reach.
      final rec = _record([
        for (var i = 0; i <= 30; i++) (micros: i * 16667, x: i * 16.7, y: 0.0),
        for (var i = 1; i <= 30; i++)
          (micros: (30 + i) * 16667, x: 500.0, y: i * 16.7),
      ]);
      final atCorner = smoothedCursorAt(
          rec, const Duration(microseconds: 30 * 16667), none, sigma)!;
      // Inside the corner means: x pulled back below 500 AND y pulled up
      // above 0 simultaneously.
      expect(atCorner.x, lessThan(500.0));
      expect(atCorner.y, greaterThan(0.0));
      // Bounded: within the reach of one window arm (2σ × path speed
      // ≈ 160ms × 1000px/s = 160px), comfortably.
      expect(500.0 - atCorner.x, lessThan(160.0));
      expect(atCorner.y, lessThan(160.0));
    });

    test('is a pure function of position (query order irrelevant)', () {
      final rec = _record([
        for (var i = 0; i <= 60; i++)
          (micros: i * 16667, x: i * 10.0, y: math.sin(i / 3) * 40),
      ]);
      Object sample(int ms) {
        final s =
            smoothedCursorAt(rec, Duration(milliseconds: ms), none, sigma)!;
        return (s.x, s.y);
      }

      final fwd = [sample(200), sample(500), sample(800)];
      final rev = [sample(800), sample(500), sample(200)];
      expect(fwd[0], rev[2]);
      expect(fwd[1], rev[1]);
      expect(fwd[2], rev[0]);
    });

    test('empty recording returns null', () {
      final rec = CursorRecording();
      expect(
          smoothedCursorAt(
              rec, const Duration(milliseconds: 100), none, sigma),
          isNull);
    });

    test('click/state come from the center tap, not the window', () {
      final rec = CursorRecording();
      for (var i = 0; i <= 60; i++) {
        rec.addPosition(CursorPosition(
          x: i * 10.0,
          y: 0,
          timestampMicros: i * 16667,
          isClicked: i == 30,
        ));
      }
      // Query exactly at the clicked sample: isClicked must survive
      // smoothing even though neighboring taps are unclicked.
      final s = smoothedCursorAt(
          rec, const Duration(microseconds: 30 * 16667), none, sigma)!;
      expect(s.isClicked, isTrue);
    });
  });

  group('pathSmoothingSigma preset wiring', () {
    test('only Smooth smooths the path', () {
      expect(CursorAnimationStyle.smooth.pathSmoothingSigma,
          const Duration(milliseconds: 80));
      expect(CursorAnimationStyle.medium.pathSmoothingSigma, Duration.zero);
      expect(CursorAnimationStyle.rapid.pathSmoothingSigma, Duration.zero);
      expect(CursorAnimationStyle.none.pathSmoothingSigma, Duration.zero);
    });

    test('config exposes the preset sigma', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      expect(cfg.pathSmoothingSigma,
          CursorAnimationStyle.smooth.pathSmoothingSigma);
    });
  });
}
