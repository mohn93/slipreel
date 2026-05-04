import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';

const Size _videoSize = Size(1920, 1080);

ZoomRegion _zoomAt({
  required Duration startTime,
  required Duration duration,
  Rect rect = const Rect.fromLTWH(100, 100, 200, 200),
  double zoomLevel = 2.0,
  bool followCursor = true,
  FollowMode followMode = FollowMode.centered,
  double deadzoneRatio = 0.3,
  Duration enterDuration = Duration.zero,
  Duration exitDuration = Duration.zero,
  Duration followDuration = const Duration(milliseconds: 400),
  CubicBezierCurve? followCurve,
}) {
  return ZoomRegion(
    rect: rect,
    startTime: startTime,
    duration: duration,
    zoomLevel: zoomLevel,
    enterDuration: enterDuration,
    exitDuration: exitDuration,
    followCursor: followCursor,
    followMode: followMode,
    deadzoneRatio: deadzoneRatio,
    followDuration: followDuration,
    followCurve: followCurve,
  );
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
        cursor: null,
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

      final update = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(500, 400),
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
        cursor: null,
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

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoomA, zoomB],
        cursor: const Offset(50, 50),
        videoSize: _videoSize,
      );

      final crossover = ctrl.update(
        position: const Duration(milliseconds: 1500),
        zoomRegions: [zoomA, zoomB],
        cursor: const Offset(950, 850),
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

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoomEarly, zoomLate],
        cursor: const Offset(50, 50),
        videoSize: _videoSize,
      );

      final mid = ctrl.update(
        position: const Duration(milliseconds: 2000),
        zoomRegions: [zoomEarly, zoomLate],
        cursor: const Offset(500, 500),
        videoSize: _videoSize,
      );
      expect(mid, isNull);
      expect(ctrl.smoothedFocal, isNull);

      final reEntry = ctrl.update(
        position: const Duration(milliseconds: 3500),
        zoomRegions: [zoomEarly, zoomLate],
        cursor: const Offset(850, 850),
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

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(100, 100),
        videoSize: _videoSize,
      );
      expect(ctrl.smoothedFocal, const Offset(100, 100));

      ctrl.reset();
      expect(ctrl.smoothedFocal, isNull);

      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursor: const Offset(200, 200),
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

      final update = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(700, 600),
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

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(100, 100),
        videoSize: _videoSize,
      );

      final firstAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(700, 600),
        videoSize: _videoSize,
      );
      final secondAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(700, 600),
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

      final out = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(1500, 900),
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
        followMode: FollowMode.bounded,
        deadzoneRatio: 0.3,
      );

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: _videoSize,
      );
      final f2 = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursor: const Offset(1000, 560),
        videoSize: _videoSize,
      );
      final f3 = ctrl.update(
        position: const Duration(seconds: 2),
        zoomRegions: [zoom],
        cursor: const Offset(1050, 580),
        videoSize: _videoSize,
      );

      expect(f2!.focal, const Offset(960, 540));
      expect(f3!.focal, const Offset(960, 540));
    });

    // --- duration / curve tween ------------------------------------------

    test(
        'tween reaches captured target after followDuration with '
        'easeOutCubic default', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: const Duration(milliseconds: 400),
      );

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      // Frame 2 — cursor jumps. Tween starts.
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(100, 0),
        videoSize: _videoSize,
      );
      final settled = ctrl.update(
        position: const Duration(milliseconds: 16 + 400),
        zoomRegions: [zoom],
        cursor: const Offset(100, 0),
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

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      final f2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(200, 0),
        videoSize: _videoSize,
      );

      expect(f2!.focal, const Offset(200, 0));
    });

    test('mid-tween retarget keeps elapsed and from but updates to', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: const Duration(milliseconds: 400),
      );

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(100, 0),
        videoSize: _videoSize,
      );
      ctrl.update(
        position: const Duration(milliseconds: 200),
        zoomRegions: [zoom],
        cursor: const Offset(200, 0),
        videoSize: _videoSize,
      );
      final settled = ctrl.update(
        position: const Duration(milliseconds: 16 + 400),
        zoomRegions: [zoom],
        cursor: const Offset(200, 0),
        videoSize: _videoSize,
      );

      expect(settled!.focal.dx, closeTo(200, 1e-6),
          reason: 'tween must re-aim at the latest cursor target');
    });

    test(
        'tween runs to completion even when cursor briefly re-enters the '
        'moving deadzone (no mid-tween abort)', () {
      // Earlier the controller aborted the tween whenever the moving
      // deadzone briefly re-contained the cursor. During steady cursor
      // motion that triggered every frame, producing visible jitter.
      // The deadzone is now a *trigger* for starting tweens only —
      // once a tween is in flight it runs to completion, re-aiming at
      // the cursor every frame. Pin that semantics in.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        followMode: FollowMode.bounded,
        deadzoneRatio: 0.3,
        followDuration: const Duration(milliseconds: 400),
      );

      // Initial focal at (960, 540).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: _videoSize,
      );
      // Cursor exits the initial deadzone (range 816..1104 around
      // (960, 540)) at (1200, 540) → tween starts.
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(1200, 540),
        videoSize: _videoSize,
      );
      // Mid-tween the cursor returns to (1000, 540) — inside the
      // initial deadzone, but the focal has moved on. Old logic
      // aborted here; new logic re-aims `to` to (1000, 540).
      ctrl.update(
        position: const Duration(milliseconds: 100),
        zoomRegions: [zoom],
        cursor: const Offset(1000, 540),
        videoSize: _videoSize,
      );
      // After full followDuration since the tween began (16 + 400 ms)
      // the focal must equal the latest cursor target (1000, 540).
      final settled = ctrl.update(
        position: const Duration(milliseconds: 16 + 400),
        zoomRegions: [zoom],
        cursor: const Offset(1000, 540),
        videoSize: _videoSize,
      );

      expect(settled!.focal.dx, closeTo(1000, 1e-6));
      expect(settled.focal.dy, closeTo(540, 1e-6));
    });

    test(
        'after a tween completes, the deadzone re-engages around the '
        'new focal so further small cursor moves are ignored', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        followMode: FollowMode.bounded,
        deadzoneRatio: 0.3,
        followDuration: const Duration(milliseconds: 400),
      );

      // Snap then trigger a tween out to (1200, 540).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: _videoSize,
      );
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(1200, 540),
        videoSize: _videoSize,
      );
      // Let the tween finish at the captured target.
      final finished = ctrl.update(
        position: const Duration(milliseconds: 16 + 400),
        zoomRegions: [zoom],
        cursor: const Offset(1200, 540),
        videoSize: _videoSize,
      );
      expect(finished!.focal.dx, closeTo(1200, 1e-6));

      // New deadzone is centered on (1200, 540), half-width 144 →
      // range 1056..1344. A cursor at (1180, 540) sits inside, so
      // the focal must hold; no fresh tween should start.
      final still = ctrl.update(
        position: const Duration(milliseconds: 500),
        zoomRegions: [zoom],
        cursor: const Offset(1180, 540),
        videoSize: _videoSize,
      );
      expect(still!.focal.dx, closeTo(1200, 1e-6),
          reason: 'cursor inside the new deadzone — focal should hold');
    });

    test('followCurve override shapes the tween progress', () {
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
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      ctrlA.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [linearZoom],
        cursor: const Offset(100, 0),
        videoSize: _videoSize,
      );
      final linearMid = ctrlA.update(
        position: const Duration(milliseconds: 16 + 200),
        zoomRegions: [linearZoom],
        cursor: const Offset(100, 0),
        videoSize: _videoSize,
      );
      expect(linearMid!.focal.dx, closeTo(50, 0.5));

      final easeZoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: dur,
      );
      final ctrlB = ZoomFocalController();
      ctrlB.update(
        position: Duration.zero,
        zoomRegions: [easeZoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      ctrlB.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [easeZoom],
        cursor: const Offset(100, 0),
        videoSize: _videoSize,
      );
      final easeMid = ctrlB.update(
        position: const Duration(milliseconds: 16 + 200),
        zoomRegions: [easeZoom],
        cursor: const Offset(100, 0),
        videoSize: _videoSize,
      );

      // Curves.easeOutCubic ≈ 0.875 at t=0.5 (Cubic-bezier
      // approximation of 1-(1-t)^3, not the analytical curve).
      expect(easeMid!.focal.dx, closeTo(87.5, 0.5));
    });

    test(
        'editing a zoom region while paused at the same position takes '
        'effect on the next update (no stale-cache hangover)', () {
      // Regression for "settings on the side panel don't apply till I
      // change them again to take effect": the controller used to
      // cache by position only, so a setting edit at a paused playhead
      // returned the focal computed under the old settings. Now the
      // controller looks up the active zoom every call and snaps when
      // a fresh ZoomRegion instance arrives — which is what
      // copyWith() produces.
      final ctrl = ZoomFocalController();
      final initial = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        followCursor: true,
      );

      // Establish state at position P with the original zoom.
      ctrl.update(
        position: const Duration(milliseconds: 500),
        zoomRegions: [initial],
        cursor: const Offset(50, 50),
        videoSize: _videoSize,
      );

      // User flips the zoom's followCursor toggle off — copyWith
      // returns a fresh ZoomRegion instance with the same identity
      // hash but different equality. The controller must pick up
      // the change without the playhead moving.
      final edited = initial.copyWith(followCursor: false);
      final out = ctrl.update(
        position: const Duration(milliseconds: 500), // same P
        zoomRegions: [edited],
        cursor: const Offset(50, 50),
        videoSize: _videoSize,
      );

      // followCursor=false pins focal to rect.center = (50, 50).
      // (Identical here to the earlier cursor coincidentally — what
      // matters is the snap branch fired and the focal is now the
      // rect.center even though only the toggle changed.)
      expect(out!.focal, const Offset(50, 50));

      // And the zoom in the result is the new instance, not the old.
      expect(identical(out.zoom, edited), isTrue,
          reason:
              'controller must report the freshly-edited zoom region, '
              'not the cached one from the previous call');
    });

    test(
        'cursor matches sprite when caller passes a smoothed cursor — '
        'no drift between camera and the visible cursor', () {
      // Regression: previously the controller looked up the cursor
      // from a CursorRecording while the visible sprite was drawn at
      // an FIR-smoothed offset, so the camera centered on a different
      // cursor than the one on screen. New API takes the same offset
      // the sprite renders at, so they cannot disagree.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        followDuration: Duration.zero, // snap so we can compare directly
      );

      // Caller has already smoothed the cursor — the camera must
      // track the smoothed position, not whatever a hypothetical
      // recording would say.
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(500, 400),
        videoSize: _videoSize,
      );
      final update = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(540, 410),
        videoSize: _videoSize,
      );

      expect(update!.focal, const Offset(540, 410));
    });

    test(
        'tween started inside the enter ramp ends exactly when the '
        'zoom ramp ends — sync, not stagger', () {
      // 1.5s enter ramp, very short followDuration (300ms). If the
      // sync logic is wrong, the focal lands at the cursor at +300ms
      // and sits there for 1.2s while the zoom is still ramping in.
      // With sync the tween extends to fill the full enter window.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        enterDuration: const Duration(milliseconds: 1500),
        followDuration: const Duration(milliseconds: 300),
      );

      // Frame 0: cursor at A — focal snaps to cursor. No tween yet.
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(500, 400),
        videoSize: _videoSize,
      );

      // 16ms in (still inside enter): cursor jumps to B. A tween
      // starts here; with sync it should end at +1500ms (the enter
      // ramp's end), not +316ms.
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(900, 600),
        videoSize: _videoSize,
      );

      // At +316ms (16ms tween-start + 300ms followDuration), the OLD
      // behavior would have the focal already at (900, 600). Under
      // sync, it should still be lerping (not yet at the target).
      final mid = ctrl.update(
        position: const Duration(milliseconds: 316),
        zoomRegions: [zoom],
        cursor: const Offset(900, 600),
        videoSize: _videoSize,
      );
      expect(mid!.focal, isNot(const Offset(900, 600)),
          reason: 'tween must not finish before the enter ramp');

      // At +1500ms — the enter ramp's end — the tween must have
      // landed: focal == B.
      final end = ctrl.update(
        position: const Duration(milliseconds: 1500),
        zoomRegions: [zoom],
        cursor: const Offset(900, 600),
        videoSize: _videoSize,
      );
      expect(end!.focal, const Offset(900, 600),
          reason:
              'tween must land at target by the time the zoom ramp ends');
    });

    test(
        'focal AND zoom factor both finish on the exact frame the '
        'enter ramp ends — no stagger, no overshoot', () {
      // Ground-truth integration: drive the focal controller and the
      // zoom transformer through the full enter ramp at 16ms ticks
      // and assert that on the boundary frame the focal == cursor
      // AND the zoom factor == zoomLevel. Anywhere strictly before
      // that frame, neither is "done" yet.
      final ctrl = ZoomFocalController();
      final transformer = ZoomTransformer();
      const enterMs = 1500;
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        enterDuration: const Duration(milliseconds: enterMs),
        followDuration: const Duration(milliseconds: 300),
      );

      const target = Offset(900, 600);

      // Frame 0: focal snaps to (500, 400).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(500, 400),
        videoSize: _videoSize,
      );

      // Frame 1: cursor jumps. A tween starts here, length = 1500-16ms.
      ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: target,
        videoSize: _videoSize,
      );

      // Walk every frame until just before the ramp ends. Both the
      // zoom factor must be < zoomLevel and the focal must be != target.
      for (var ms = 32; ms < enterMs; ms += 16) {
        final pos = Duration(milliseconds: ms);
        final out = ctrl.update(
          position: pos,
          zoomRegions: [zoom],
          cursor: target,
          videoSize: _videoSize,
        );
        final z = transformer.getTransform(
          position: pos,
          zoomRegion: zoom,
          videoSize: _videoSize,
        );

        expect(z.isIdentity(), isFalse,
            reason: 'zoom should be ramping at t=${ms}ms');
        // The transform isn't a pure scale because of the focal
        // re-centering, but its scale-x entry is the zoom factor.
        final zoomFactor = z.entry(0, 0);
        expect(zoomFactor, lessThan(zoom.zoomLevel),
            reason: 'zoom factor must not be at full zoom yet at t=${ms}ms');
        expect(out!.focal, isNot(target),
            reason: 'focal must not be at the cursor yet at t=${ms}ms');
      }

      // The boundary frame: enter ramp ends, focal lands on cursor,
      // zoom factor reaches zoomLevel.
      final endPos = const Duration(milliseconds: enterMs);
      final outAtEnd = ctrl.update(
        position: endPos,
        zoomRegions: [zoom],
        cursor: target,
        videoSize: _videoSize,
      );
      final zAtEnd = transformer.getTransform(
        position: endPos,
        zoomRegion: zoom,
        videoSize: _videoSize,
      );
      expect(outAtEnd!.focal, target);
      expect(zAtEnd.entry(0, 0), zoom.zoomLevel);
    });

    test(
        'mid-zoom (post-enter) cursor moves still use the user-tuned '
        'followDuration', () {
      // The sync rule only fires inside the enter / exit ramps. Once
      // we're in the hold phase, a fresh tween should run for exactly
      // followDuration, not stretch to the end of the region.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 10),
        enterDuration: const Duration(milliseconds: 500),
        followDuration: const Duration(milliseconds: 400),
      );

      // Warm into the hold phase past the enter ramp.
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(500, 400),
        videoSize: _videoSize,
      );
      ctrl.update(
        position: const Duration(milliseconds: 600),
        zoomRegions: [zoom],
        cursor: const Offset(500, 400),
        videoSize: _videoSize,
      );

      // Cursor jumps mid-hold; tween must complete in followDuration
      // (400ms), not anything longer.
      ctrl.update(
        position: const Duration(milliseconds: 700),
        zoomRegions: [zoom],
        cursor: const Offset(900, 600),
        videoSize: _videoSize,
      );
      final landed = ctrl.update(
        // 700 + 400 = 1100 → tween should be done.
        position: const Duration(milliseconds: 1100),
        zoomRegions: [zoom],
        cursor: const Offset(900, 600),
        videoSize: _videoSize,
      );
      expect(landed!.focal, const Offset(900, 600));
    });
  });
}
