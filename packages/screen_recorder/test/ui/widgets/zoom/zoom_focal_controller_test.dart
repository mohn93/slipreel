import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

const Size _videoSize = Size(1920, 1080);

ZoomRegion _zoomAt({
  required Duration startTime,
  required Duration duration,
  Rect rect = const Rect.fromLTWH(100, 100, 200, 200),
  double zoomLevel = 2.0,
  bool followCursor = true,
  bool boundedFollow = false,
  double deadzoneRatio = 0.3,
  Duration followDuration = const Duration(milliseconds: 400),
  CubicBezierCurve? followCurve,
}) {
  return ZoomRegion(
    rect: rect,
    startTime: startTime,
    duration: duration,
    zoomLevel: zoomLevel,
    enterDuration: Duration.zero,
    exitDuration: Duration.zero,
    followCursor: followCursor,
    boundedFollow: boundedFollow,
    deadzoneRatio: deadzoneRatio,
    followDuration: followDuration,
    followCurve: followCurve,
  );
}

CursorRecording _recordingAt(List<({int micros, double x, double y})> samples) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(CursorPosition(
        x: s.x, y: s.y, timestampMicros: s.micros));
  }
  return r;
}

void main() {
  group('ZoomFocalController', () {
    test('returns null when no zoom is active', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: const Duration(seconds: 1),
        duration: const Duration(seconds: 1),
      );

      final update = ctrl.update(
        position: const Duration(milliseconds: 500),
        zoomRegions: [zoom],
        cursorRecording: _recordingAt([]),
        videoSize: _videoSize,
      );

      expect(update, isNull);
      expect(ctrl.smoothedFocal, isNull);
    });

    test('snaps to cursor position on the first frame of a zoom', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(0, 0, 100, 100),
      );
      final cursor = _recordingAt([
        (micros: 0, x: 500, y: 400),
      ]);

      final update = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(update, isNotNull);
      expect(update!.zoom, same(zoom));
      expect(update.focal, const Offset(500, 400),
          reason: 'first frame of a zoom must snap, not lerp');
    });

    test('falls back to rect.center when no cursor sample exists', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(200, 100, 400, 300),
      );

      final update = ctrl.update(
        position: const Duration(milliseconds: 500),
        zoomRegions: [zoom],
        cursorRecording: _recordingAt([]),
        videoSize: _videoSize,
      );

      expect(update, isNotNull);
      expect(update!.focal, const Offset(400, 250));
    });

    test(
        'snaps focal when crossing into a different zoom region '
        'instead of lerping across the screen', () {
      final ctrl = ZoomFocalController();
      final zoomA = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(0, 0, 100, 100),
      );
      final zoomB = _zoomAt(
        startTime: const Duration(seconds: 1),
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(900, 800, 100, 100),
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 50,  y: 50),
        (micros: 1_500_000, x: 950, y: 850),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoomA, zoomB],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      final crossover = ctrl.update(
        position: const Duration(milliseconds: 1500),
        zoomRegions: [zoomA, zoomB],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(crossover, isNotNull);
      expect(crossover!.zoom, same(zoomB));
      expect(crossover.focal, const Offset(950, 850));
    });

    test(
        'clears smoothing state when leaving a zoom so the next entry '
        'snaps cleanly', () {
      final ctrl = ZoomFocalController();
      final zoomEarly = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(0, 0, 100, 100),
      );
      final zoomLate = _zoomAt(
        startTime: const Duration(seconds: 3),
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(800, 800, 100, 100),
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 50,  y: 50),
        (micros: 3_500_000, x: 850, y: 850),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      final mid = ctrl.update(
        position: const Duration(milliseconds: 2000),
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(mid, isNull);
      expect(ctrl.smoothedFocal, isNull);

      final reEntry = ctrl.update(
        position: const Duration(milliseconds: 3500),
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(reEntry!.focal, const Offset(850, 850));
    });

    test('reset() drops state so the next call snaps', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 100, y: 100),
        (micros: 1_000_000, x: 200, y: 200),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(ctrl.smoothedFocal, const Offset(100, 100));

      ctrl.reset();
      expect(ctrl.smoothedFocal, isNull);

      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(update!.focal, const Offset(200, 200));
    });

    test('exposes the current smoothed focal for debug HUDs', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
      );
      final cursor = _recordingAt([
        (micros: 0, x: 700, y: 600),
      ]);

      final update = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(ctrl.smoothedFocal, update!.focal);
    });

    test('repeated update() at the same position is idempotent', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
      );
      final cursor = _recordingAt([
        (micros: 0, x: 100, y: 100),
        (micros: 16000, x: 700, y: 600),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      final firstAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final secondAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(secondAtT2!.focal, firstAtT2!.focal);
    });

    // --- followCursor / boundedFollow / deadzone semantics ---------------

    test('followCursor=false pins focal to rect.center even with cursor data',
        () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(200, 100, 400, 300),
        followCursor: false,
      );
      final cursor = _recordingAt([
        (micros: 0, x: 1500, y: 900),
      ]);

      final out = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(out!.focal, const Offset(400, 250));
    });

    test('bounded follow holds focal while cursor stays inside the deadzone',
        () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        boundedFollow: true,
        deadzoneRatio: 0.3,
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 960, y: 540),
        (micros: 1_000_000, x: 1000, y: 560),
        (micros: 2_000_000, x: 1050, y: 580),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final f2 = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final f3 = ctrl.update(
        position: const Duration(seconds: 2),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(f2!.focal, const Offset(960, 540));
      expect(f3!.focal, const Offset(960, 540));
    });

    // --- duration / curve tween ------------------------------------------

    test(
        'tween reaches captured target after followDuration with '
        'easeOutCubic default', () {
      // Always-centered (no deadzone). Cursor jumps from (0,0) to
      // (100,0) at t=0. By t=followDuration the focal must equal
      // (100, 0) regardless of curve shape (curve(1)=1).
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: const Duration(milliseconds: 400),
      );
      final cursor = _recordingAt([
        (micros: 0,        x: 0,   y: 0),
        (micros: 1_000,    x: 100, y: 0), // jumps almost immediately
      ]);

      // First frame snaps to (0, 0).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      // Frame 2 — cursor now at (100, 0). Tween starts.
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      // After followDuration has elapsed since the tween started.
      final settled = ctrl.update(
        position: const Duration(milliseconds: 16 + 400),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(settled!.focal.dx, closeTo(100, 1e-6));
      expect(settled.focal.dy, closeTo(0, 1e-6));
    });

    test('followDuration=0 snaps the focal to the cursor each frame',
        () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: Duration.zero,
      );
      final cursor = _recordingAt([
        (micros: 0,        x: 0,   y: 0),
        (micros: 16_000,   x: 200, y: 0),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final f2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(f2!.focal, const Offset(200, 0));
    });

    test('mid-tween retarget keeps elapsed and from but updates to', () {
      // Cursor jumps to (100, 0), then halfway through the tween it
      // jumps further to (200, 0). The tween's `from` and start time
      // must stay locked, only `to` updates — so the final landing
      // point at t=followDuration is (200, 0), not (100, 0).
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: const Duration(milliseconds: 400),
      );
      final cursor = _recordingAt([
        (micros: 0,        x: 0,   y: 0),
        (micros: 16_000,   x: 100, y: 0),
        (micros: 200_000,  x: 200, y: 0),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      // Tween starts here aiming at (100, 0).
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      // Mid-tween — cursor moves to (200, 0). Re-target.
      ctrl.update(
        position: const Duration(milliseconds: 200),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      // After full followDuration since the tween started.
      final settled = ctrl.update(
        position: const Duration(milliseconds: 16 + 400),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(settled!.focal.dx, closeTo(200, 1e-6),
          reason: 'tween must re-aim at the latest cursor target');
    });

    test('tween aborts when cursor settles back into the deadzone', () {
      // Bounded follow with a small cursor excursion. Initial focal
      // (960, 540), zoom=2 → viewport 960×540, deadzone 30% →
      // half-width 144 px (range 816..1104 around the focal).
      //
      // Cursor jumps to (1200, 540) → outside, tween starts toward
      // (1200, 540). After 100 ms (eased ≈ 0.508) the focal lands
      // at ~(1082, 540) and its deadzone is now (938..1226). The
      // cursor returns to (1000, 540), which is *inside* that
      // shifted deadzone, so the tween must abort and the focal
      // must hold (1082, 540) for the rest of the run.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        boundedFollow: true,
        deadzoneRatio: 0.3,
        followDuration: const Duration(milliseconds: 400),
      );
      final cursor = _recordingAt([
        (micros: 0,        x: 960,  y: 540),
        (micros: 16_000,   x: 1200, y: 540), // outside initial dz
        (micros: 100_000,  x: 1000, y: 540), // inside the shifted dz
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final atAbort = ctrl.update(
        position: const Duration(milliseconds: 100),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final later = ctrl.update(
        position: const Duration(milliseconds: 800),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(later!.focal, atAbort!.focal,
          reason:
              'cursor re-entered the (moving) deadzone — focal must '
              'stay put instead of completing the tween toward '
              '(1200, 540)');
    });

    test('followCurve override shapes the tween progress', () {
      // Linear vs. easeOutCubic: at half the followDuration,
      //   - linear → focal at 50% of the gap
      //   - easeOutCubic → focal at 1 - 0.5^3 = 87.5%
      // Ship the same recording through both configs and check.
      final cursor = _recordingAt([
        (micros: 0,        x: 0,   y: 0),
        (micros: 1_000,    x: 100, y: 0),
      ]);
      final dur = const Duration(milliseconds: 400);

      final linearZoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: dur,
        followCurve:
            const CubicBezierCurve(x1: 0, y1: 0, x2: 1, y2: 1),
      );
      final ctrlA = ZoomFocalController();
      ctrlA.update(
        position: Duration.zero,
        zoomRegions: [linearZoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      ctrlA.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [linearZoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final linearMid = ctrlA.update(
        position: const Duration(milliseconds: 16 + 200),
        zoomRegions: [linearZoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      // Linear at t=0.5 → 50.
      expect(linearMid!.focal.dx, closeTo(50, 0.5));

      // Default easeOutCubic at the same elapsed.
      final easeZoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: dur,
        // followCurve null → controller uses Curves.easeOutCubic.
      );
      final ctrlB = ZoomFocalController();
      ctrlB.update(
        position: Duration.zero,
        zoomRegions: [easeZoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      ctrlB.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [easeZoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final easeMid = ctrlB.update(
        position: const Duration(milliseconds: 16 + 200),
        zoomRegions: [easeZoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      // Curves.easeOutCubic is a Cubic-bezier approximation of
      // 1-(1-t)^3 (≈ 0.87512 at t=0.5), not the analytical curve.
      // Loose tolerance keeps the test robust to that approximation.
      expect(easeMid!.focal.dx, closeTo(87.5, 0.5));
    });
  });
}
