import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';

const Size _videoSize = Size(1920, 1080);

ZoomRegion _zoomAt({
  required Duration startTime,
  required Duration duration,
  // Centred on the origin so the first-frame snap (focal := rect.center)
  // matches the (0,0) cursor positions most tests start from. Tests
  // that care about a specific rect.center override this explicitly.
  Rect rect = const Rect.fromLTRB(0, 0, 0, 0),
  double zoomLevel = 2.0,
  bool followCursor = true,
  FollowMode followMode = FollowMode.centered,
  double deadzoneRatio = 0.3,
  Duration enterDuration = Duration.zero,
  Duration exitDuration = Duration.zero,
  Duration followDuration = const Duration(milliseconds: 400),
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
  );
}

/// Walk the focal controller forward from `from` to `to` at 16 ms
/// frame intervals, holding [cursor] constant. Returns the final
/// update. The spring needs sufficient sub-stepping resolution to
/// settle, and most tests want "after N ms, where is the focal" not
/// "after one large dt jump" — driving frame-by-frame mirrors real
/// playback dt and gives the spring enough integration time to
/// approach its target.
ZoomFocalUpdate? _drive(
  ZoomFocalController ctrl,
  ZoomRegion zoom, {
  required Duration from,
  required Duration to,
  required Offset cursor,
  Duration step = const Duration(milliseconds: 16),
}) {
  ZoomFocalUpdate? last;
  var t = from + step;
  while (t <= to) {
    last = ctrl.update(
      position: t,
      zoomRegions: [zoom],
      cursor: cursor,
      videoSize: _videoSize,
    );
    t += step;
  }
  return last;
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

    test(
        'first frame of a zoom snaps to the rect centre — regardless of '
        'cursor position', () {
      // The user drew a zoom rect around a specific area; the camera
      // should frame *that area* when the zoom kicks in. The bounded
      // gate (followCursor + dz) then decides whether to chase the
      // cursor or stay put.
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
      expect(update.focal, const Offset(50, 50),
          reason: 'first frame of a zoom must land on rect.center, '
              'not on the cursor');
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
        'crossing into a different zoom region spring-chases the new '
        'rect, no instant snap', () {
      // All-spring policy: crossing from one zoom region to another
      // is just another change of target. The spring carries the
      // focal smoothly from zoomA's rect.center toward zoomB's
      // rect.center — no teleport. We don't expect the focal to be
      // *at* zoomB.rect.center on the very first frame of zoomB; we
      // expect it to be advancing toward it from the previous spring
      // state.
      final ctrl = ZoomFocalController();
      final zoomA = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(0, 0, 100, 100), // center (50, 50)
      );
      final zoomB = _zoomAt(
        startTime: const Duration(seconds: 1),
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(900, 800, 100, 100), // center (950, 850)
      );

      // Settle the spring on zoomA at (50, 50).
      _drive(
        ctrl,
        zoomA,
        from: Duration.zero,
        to: const Duration(milliseconds: 800),
        cursor: const Offset(50, 50),
      );
      final endOfA = ctrl.update(
        position: const Duration(milliseconds: 999),
        zoomRegions: [zoomA, zoomB],
        cursor: const Offset(50, 50),
        videoSize: _videoSize,
      );
      expect(endOfA!.focal.dx, closeTo(50, 2));
      expect(endOfA.focal.dy, closeTo(50, 2));

      // First frame in zoomB: spring continues from ~(50, 50). It is
      // NOT instantly at (950, 850).
      final crossover = ctrl.update(
        position: const Duration(milliseconds: 1016),
        zoomRegions: [zoomA, zoomB],
        cursor: const Offset(950, 850),
        videoSize: _videoSize,
      );
      expect(crossover, isNotNull);
      expect(crossover!.zoom, same(zoomB));
      expect(crossover.focal.dx, lessThan(200),
          reason: 'spring must still be near zoomA.center on the '
              'very first frame of zoomB — not snapped to zoomB.center');
      expect(crossover.focal.dy, lessThan(200));

      // After driving inside zoomB for a while (staying within its
      // 1000–2000 ms active window), the spring should have made
      // meaningful progress toward zoomB.center.
      final settled = _drive(
        ctrl,
        zoomB,
        from: const Duration(milliseconds: 1016),
        to: const Duration(milliseconds: 1980),
        cursor: const Offset(950, 850),
      );
      expect(settled!.focal.dx, greaterThan(700),
          reason: 'spring should have advanced well toward zoomB.center');
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
      // zoomLate's rect.center == (850, 850).
      expect(reEntry!.focal, const Offset(850, 850));
    });

    test('reset() drops state so the next call snaps', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTRB(100, 100, 100, 100),
      );

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(100, 100),
        videoSize: _videoSize,
      );
      // First call snaps focal to rect.center == (100, 100).
      expect(ctrl.smoothedFocal, const Offset(100, 100));

      ctrl.reset();
      expect(ctrl.smoothedFocal, isNull);

      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursor: const Offset(200, 200),
        videoSize: _videoSize,
      );
      // After reset, next update re-snaps to rect.center, not cursor.
      expect(update!.focal, const Offset(100, 100));
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

    test(
        'stiff spring + jittering cursor inside a large deadzone — focal '
        'holds (no slow drift toward the cursor)', () {
      // Regression for "camera slowly drifts toward the cursor" with
      // followDuration=100 ms (stiff spring) and a wide deadzone. The
      // prior velocity-bypass would let a sub-pixel post-snap twitch
      // push speed above the threshold and leave the deadzone gate
      // permanently disengaged, so even tiny cursor wanders ended up
      // moving the camera. With the [_inFlight] flag the gate only
      // disengages on a real deadzone exit.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        followMode: FollowMode.bounded,
        deadzoneRatio: 1.01,
        followDuration: const Duration(milliseconds: 100),
        // rect.center placed at the cursor's starting position so the
        // initial snap (focal := rect.center) coincides with the
        // cursor — exactly the steady-state we want to verify holds.
        rect: const Rect.fromLTRB(960, 540, 960, 540),
      );

      // Snap to rect.center == (960, 540).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: _videoSize,
      );
      // Walk the cursor randomly within ~50 px of the snap point
      // (well inside the dz half-width ≈ 485 px). The focal must not
      // move from where it snapped.
      const wanderRadius = 50.0;
      var seed = 1.0;
      for (var ms = 16; ms <= 2000; ms += 16) {
        // Deterministic pseudo-random walk so test outcomes are stable.
        seed = (seed * 1103515245 + 12345) % 2147483648;
        final dx = (seed / 2147483648 - 0.5) * 2 * wanderRadius;
        seed = (seed * 1103515245 + 12345) % 2147483648;
        final dy = (seed / 2147483648 - 0.5) * 2 * wanderRadius;
        final out = ctrl.update(
          position: Duration(milliseconds: ms),
          zoomRegions: [zoom],
          cursor: Offset(960 + dx, 540 + dy),
          videoSize: _videoSize,
        );
        // Focal must stay exactly at the snap point (no drift).
        expect(out!.focal.dx, closeTo(960, 1e-9),
            reason: 'focal must not drift inside a wide deadzone (t=${ms}ms)');
        expect(out.focal.dy, closeTo(540, 1e-9));
      }
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
        // rect.center coincides with the initial cursor so the snap
        // lands inside the deadzone immediately.
        rect: const Rect.fromLTRB(960, 540, 960, 540),
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

    // --- spring dynamics --------------------------------------------------

    test('spring reaches target within ~3× settle time', () {
      // The spring is critically damped → no overshoot. After
      // ~3 × followDuration it should be within a couple of pixels
      // of the cursor target. This replaces the old tween test's
      // "exact arrival at followDuration" assertion since a critically-
      // damped spring is only ~95% there at one settle time.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        followDuration: const Duration(milliseconds: 400),
      );

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      // Drive the controller from t=0 to t=1.5s (≈ 3.75× settle time)
      // with the cursor at (100, 0). After 3× the camera should be
      // visually arrived (within a few px of the cursor).
      final settled = _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 1500),
        cursor: const Offset(100, 0),
      );

      expect(settled!.focal.dx, closeTo(100, 2));
      expect(settled.focal.dy, closeTo(0, 2));
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

    test('spring chases the latest cursor target, not earlier ones', () {
      // Cursor sweeps 0 → 100 → 200 over the first 200 ms. The spring
      // should end up homing in on (200, 0), not the intermediate
      // (100, 0). Given the spring chases each frame's target, by the
      // time we've driven for 3× settle time past the second jump the
      // focal should be very close to 200.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        followDuration: const Duration(milliseconds: 400),
      );

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      // First leg: 0 → 100 over the first 200 ms.
      _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 200),
        cursor: const Offset(100, 0),
      );
      // Second leg: target jumps to (200, 0). Drive long enough for
      // the spring to settle on the new target (~3× settle = 1200 ms).
      final settled = _drive(
        ctrl,
        zoom,
        from: const Duration(milliseconds: 200),
        to: const Duration(milliseconds: 200 + 1500),
        cursor: const Offset(200, 0),
      );

      expect(settled!.focal.dx, closeTo(200, 2),
          reason: 'spring must home in on the latest cursor target');
    });

    test(
        'cursor returning inside the moving deadzone stops the chase '
        '(leash semantic, not full re-center)', () {
      // The bounded gate is purely positional. The moment the cursor
      // sits inside the deadzone box around the current focal, the
      // spring's target switches back to the focal — so the spring
      // decelerates from whatever velocity it had and the focal
      // settles somewhere *between* the original snap point and the
      // cursor's transient excursion. It does NOT keep chasing all
      // the way to the cursor's mid-chase position. This is the
      // "leash" behaviour: as soon as the cursor is comfortably in
      // the leash, the camera holds.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        followMode: FollowMode.bounded,
        deadzoneRatio: 0.3,
        followDuration: const Duration(milliseconds: 400),
        rect: const Rect.fromLTRB(960, 540, 960, 540),
      );

      // Initial focal at rect.center = (960, 540).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: _videoSize,
      );
      // Cursor exits the initial deadzone (range 816..1104 around
      // (960, 540)) at (1200, 540) → spring starts chasing right.
      _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 100),
        cursor: const Offset(1200, 540),
      );
      // Cursor returns to (1000, 540). The deadzone around the
      // current focal (~1000–1100) easily contains (1000, 540), so
      // the gate flips back to "hold" and the spring decelerates.
      final settled = _drive(
        ctrl,
        zoom,
        from: const Duration(milliseconds: 100),
        to: const Duration(milliseconds: 100 + 1500),
        cursor: const Offset(1000, 540),
      );

      // Focal ends somewhere between the snap (960) and the original
      // chase target (1200). It must NOT have continued all the way
      // to the cursor's transient position — that would be the
      // "commit to chase" semantic we're explicitly rejecting.
      expect(settled!.focal.dx, greaterThan(960));
      expect(settled.focal.dx, lessThan(1200));
      expect(settled.focal.dy, closeTo(540, 1));
    });

    test(
        'after the spring settles, the deadzone re-engages around the '
        'new focal so further small cursor moves are ignored', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 10),
        zoomLevel: 2.0,
        followMode: FollowMode.bounded,
        deadzoneRatio: 0.3,
        followDuration: const Duration(milliseconds: 400),
      );

      // Snap, then drive the spring out toward (1200, 540). With the
      // leash semantic the spring stops as soon as the cursor enters
      // the moving dz around the focal — i.e., when focal arrives at
      // roughly (cursor - dz_halfwidth). For 1920px video at zoom 2×
      // and dz=0.3, dz half-width = 1920/2 * 0.3 / 2 = 144px, so the
      // focal settles in the band [cursor - 144, cursor].
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: _videoSize,
      );
      final finished = _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 3000),
        cursor: const Offset(1200, 540),
      );
      // Cursor must now sit inside the dz around the resting focal —
      // the "comfortable in the leash" invariant.
      expect(finished!.focal.dx, lessThanOrEqualTo(1200));
      expect(finished.focal.dx, greaterThanOrEqualTo(1056));

      // Cursor at (1180, 540): also inside the dz around the resting
      // focal, so the spring should not pick up a fresh chase.
      final still = _drive(
        ctrl,
        zoom,
        from: const Duration(milliseconds: 3000),
        to: const Duration(milliseconds: 3500),
        cursor: const Offset(1180, 540),
      );
      expect(still!.focal.dx, closeTo(finished.focal.dx, 2),
          reason: 'cursor inside the new deadzone — focal should hold');
    });

    test(
        'tweaking a non-structural field mid-flight does not snap the '
        'spring (no jolt while dragging an inspector slider)', () {
      // copyWith() returns a fresh ZoomRegion instance every time the
      // user nudges an inspector slider. The controller used to treat
      // any fresh instance as "new zoom" and snap the focal — that
      // produced a visible jolt on every continuous-drag tick. The
      // snap path now fires only when one of the structural fields
      // changes (startTime, rect, followCursor, followMode); knobs
      // like deadzoneRatio / followDuration / enter+exitDuration /
      // zoomLevel / predictiveWindow flow through silently.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        followMode: FollowMode.bounded,
        deadzoneRatio: 0.3,
        followDuration: const Duration(milliseconds: 400),
      );
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: _videoSize,
      );
      // Spring is mid-chase toward (1200, 540) after ~96 ms (the last
      // frame _drive emits at the 16 ms step before passing 100 ms).
      _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 100),
        cursor: const Offset(1200, 540),
      );
      // Stamp the focal at the exact playhead the edit will arrive on
      // (position: 96 ms — same as _drive's last tick) so dt is 0 on
      // the edit call and we can compare focals directly.
      final beforeEdit = ctrl.update(
        position: const Duration(milliseconds: 96),
        zoomRegions: [zoom],
        cursor: const Offset(1200, 540),
        videoSize: _videoSize,
      );
      final focalBefore = beforeEdit!.focal;

      // User drags the deadzone slider — copyWith returns a new
      // instance with a different deadzoneRatio. Same playhead, same
      // cursor. The focal must NOT snap to the cursor; it must
      // continue from `focalBefore` unchanged (dt is zero on this
      // re-evaluation).
      final edited = zoom.copyWith(deadzoneRatio: 0.6);
      final afterEdit = ctrl.update(
        position: const Duration(milliseconds: 96),
        zoomRegions: [edited],
        cursor: const Offset(1200, 540),
        videoSize: _videoSize,
      );
      expect(afterEdit!.focal.dx, closeTo(focalBefore.dx, 1e-6),
          reason: 'non-structural edit must not reset the spring');
      expect(afterEdit.focal.dy, closeTo(focalBefore.dy, 1e-6));
      // And the new instance is what the controller reports back.
      expect(identical(afterEdit.zoom, edited), isTrue);
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
        'mid-zoom (post-enter) cursor moves drive the spring with the '
        'user-tuned settle time', () {
      // After the enter ramp the spring chases cursor moves using the
      // user-tuned [followDuration] as its settle time. Drive long
      // enough (≈3× settle) and the focal must land on the cursor.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 10),
        enterDuration: const Duration(milliseconds: 500),
        followDuration: const Duration(milliseconds: 400),
      );

      // Snap, then drive past the enter ramp with the cursor steady so
      // the spring settles in the starting region.
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(500, 400),
        videoSize: _videoSize,
      );
      _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 600),
        cursor: const Offset(500, 400),
      );

      // Cursor jumps mid-hold; drive 3× settle time and the spring
      // must home in on the new cursor target.
      final landed = _drive(
        ctrl,
        zoom,
        from: const Duration(milliseconds: 600),
        to: const Duration(milliseconds: 600 + 1500),
        cursor: const Offset(900, 600),
      );
      expect(landed!.focal.dx, closeTo(900, 3));
      expect(landed.focal.dy, closeTo(600, 3));
    });

    test(
        'exit ramp stops following cursor and lerps focal to video centre '
        'in lock-step with the zoom-out', () {
      // Once the zoom starts unwinding, the viewport widens every frame
      // and the user can already see where the cursor is heading. The
      // controller should stop chasing the cursor AND smoothly migrate
      // the focal toward the video centre so X and Y arrive there
      // simultaneously when the zoom hits 1.0×. Without the lerp the
      // per-axis clamp in ZoomTransformer pulls X and Y inward at
      // different rates.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(milliseconds: 1000),
        enterDuration: const Duration(milliseconds: 100),
        exitDuration: const Duration(milliseconds: 100),
        followDuration: const Duration(milliseconds: 50),
      );

      // Frame 0 (start of region): snap to cursor at (100, 100).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(100, 100),
        videoSize: _videoSize,
      );
      // Drive into the hold phase with the cursor at (500, 500) so the
      // spring settles there. _drive ticks 16 ms frames between 0 and
      // 400 ms — well past followDuration × 3 — leaving the spring
      // essentially at (500, 500) when the exit ramp starts.
      final inHold = _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 400),
        cursor: const Offset(500, 500),
      );
      expect(inHold!.focal.dx, closeTo(500, 1),
          reason: 'sanity: spring should have settled by now');
      expect(inHold.focal.dy, closeTo(500, 1));

      // Frame at 950ms — halfway through the exit ramp at 900..1000ms.
      // Cursor moves to (900, 900) but the controller ignores it. The
      // focal lerps from the captured exit-start focal toward
      // videoCentre (960, 540) using the same curve the zoom factor
      // uses, so X and Y interpolate at the same fraction.
      final midExit = ctrl.update(
        position: const Duration(milliseconds: 950),
        zoomRegions: [zoom],
        cursor: const Offset(900, 900),
        videoSize: _videoSize,
      );
      final startFocal = inHold.focal;
      const centre = Offset(960, 540);
      final progressX = (midExit!.focal.dx - startFocal.dx) /
          (centre.dx - startFocal.dx);
      final progressY = (midExit.focal.dy - startFocal.dy) /
          (centre.dy - startFocal.dy);
      expect(progressX, closeTo(progressY, 1e-9),
          reason: 'X and Y must lerp at the same progress so they finish '
              'together — that is the whole point of the explicit lerp.');
      expect(progressX, greaterThan(0));
      expect(progressX, lessThan(1));

      // Frame at the very end of the exit ramp: focal must be exactly
      // at video centre, regardless of the cursor's current position.
      final endExit = ctrl.update(
        position: const Duration(milliseconds: 1000),
        zoomRegions: [zoom],
        cursor: const Offset(900, 900),
        videoSize: _videoSize,
      );
      expect(endExit!.focal.dx, closeTo(960, 1e-6),
          reason: 'X must finish at video centre when the zoom hits 1.0×');
      expect(endExit.focal.dy, closeTo(540, 1e-6),
          reason: 'Y must finish at video centre when the zoom hits 1.0×');
    });

    test(
        'meaningful backward scrub mid-flight keeps focal in place and '
        'just zeros the spring velocity', () {
      // Under the all-spring policy the focal never teleports — not
      // even on a user-intended scrub. Instead the controller zeros
      // the spring's velocity (so stale momentum from before the
      // discontinuity doesn't carry forward) and leaves the position
      // alone. The next forward frame's spring step then accelerates
      // from rest toward whatever target the gate decides.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        followDuration: const Duration(milliseconds: 400),
        rect: const Rect.fromLTRB(123, 456, 123, 456),
      );

      // Init at rect.center, then drive forward chasing a cursor at
      // (700, 700) so the spring builds velocity.
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(100, 100),
        videoSize: _videoSize,
      );
      final beforeScrub = _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 600),
        cursor: const Offset(700, 700),
      );
      final focalBeforeScrub = beforeScrub!.focal;
      // Spring should have built non-trivial velocity by now.
      expect(ctrl.focalVelocity.distance, greaterThan(10));

      // User scrubs backward by 550 ms (well above the 200 ms floor).
      final out = ctrl.update(
        position: const Duration(milliseconds: 50),
        zoomRegions: [zoom],
        cursor: const Offset(400, 400),
        videoSize: _videoSize,
      );
      // Focal stays where it was — no teleport.
      expect(out!.focal.dx, closeTo(focalBeforeScrub.dx, 1));
      expect(out.focal.dy, closeTo(focalBeforeScrub.dy, 1));
      // Velocity is zeroed so the next forward step doesn't carry
      // stale momentum.
      expect(ctrl.focalVelocity.dx, 0);
      expect(ctrl.focalVelocity.dy, 0);
    });

    test(
        'small backward jitter (≤200 ms) does NOT snap — that case is '
        'usually a hover-scrub commit, not a user-intended seek', () {
      // Regression for "camera suddenly centres on my cursor every
      // time I click somewhere": the playhead can hiccup backwards
      // by a few tens of ms on a hover-scrub commit, and we used to
      // treat that as a real backward seek and snap. With the 200 ms
      // floor, the spring just continues from its current focal and
      // the visible camera motion stays smooth.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        followDuration: const Duration(milliseconds: 400),
      );
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(100, 100),
        videoSize: _videoSize,
      );
      final before = _drive(
        ctrl,
        zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 200),
        cursor: const Offset(700, 700),
      );
      final focalBefore = before!.focal;

      // 80 ms backward jitter, cursor changes a lot — if the snap
      // path fired, focal would teleport to (400, 400). It must NOT.
      final out = ctrl.update(
        position: const Duration(milliseconds: 120),
        zoomRegions: [zoom],
        cursor: const Offset(400, 400),
        videoSize: _videoSize,
      );
      expect(out!.focal.dx, closeTo(focalBefore.dx, 1),
          reason: 'small backward jitter must not snap the focal');
      expect(out.focal.dy, closeTo(focalBefore.dy, 1));
    });

    // --- spring-specific dynamics tests ---------------------------------

    test('spring picks up velocity when it starts chasing a target', () {
      // The focal should advance toward the target each frame even
      // before settle time elapses — otherwise the spring isn't
      // actually being stepped.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        followDuration: const Duration(milliseconds: 400),
      );
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      final f1 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursor: const Offset(500, 0),
        videoSize: _videoSize,
      );
      final f2 = ctrl.update(
        position: const Duration(milliseconds: 32),
        zoomRegions: [zoom],
        cursor: const Offset(500, 0),
        videoSize: _videoSize,
      );
      // Focal advanced toward target on each frame, monotonically.
      expect(f1!.focal.dx, greaterThan(0));
      expect(f2!.focal.dx, greaterThan(f1.focal.dx));
      // And nowhere near the target after just 32 ms (settle = 400 ms),
      // so we know we're integrating, not snapping.
      expect(f2.focal.dx, lessThan(150));
    });

    test('spring chasing a moving target stays monotonic — no overshoot',
        () {
      // Critical damping means no oscillation. Walk the cursor at a
      // constant rightward velocity and verify the focal stays behind
      // the cursor the whole time AND advances each frame.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        followDuration: const Duration(milliseconds: 400),
      );
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      var lastX = 0.0;
      for (var ms = 16; ms <= 1000; ms += 16) {
        // Cursor moves at 0.5 px/ms = 500 px/s.
        final cursorX = ms * 0.5;
        final out = ctrl.update(
          position: Duration(milliseconds: ms),
          zoomRegions: [zoom],
          cursor: Offset(cursorX, 0),
          videoSize: _videoSize,
        );
        expect(out!.focal.dx, greaterThanOrEqualTo(lastX),
            reason: 'focal must advance monotonically (no oscillation) '
                'at t=${ms}ms');
        expect(out.focal.dx, lessThanOrEqualTo(cursorX + 1),
            reason: 'focal must not pass the cursor at t=${ms}ms');
        lastX = out.focal.dx;
      }
    });

    test('large dt between calls does not blow up the spring', () {
      // After a pause-resume or scrub, the next update may carry a
      // multi-second gap. The total-dt cap (250 ms) plus sub-stepping
      // must keep the integration stable — the focal must NOT go to
      // NaN, infinity, or shoot past the target by orders of magnitude.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 30),
        followDuration: const Duration(milliseconds: 400),
      );
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursor: const Offset(0, 0),
        videoSize: _videoSize,
      );
      // Massive forward jump (5 s) with the cursor 1000 px away.
      final out = ctrl.update(
        position: const Duration(seconds: 5),
        zoomRegions: [zoom],
        cursor: const Offset(1000, 0),
        videoSize: _videoSize,
      );
      expect(out!.focal.dx.isFinite, isTrue);
      expect(out.focal.dy.isFinite, isTrue);
      // The dt cap means the spring only integrates 250 ms worth on
      // this call (well short of settle). Focal must lie strictly
      // between the start (0) and the target (1000).
      expect(out.focal.dx, greaterThan(0));
      expect(out.focal.dx, lessThan(1000));
    });
  });

  test('exit ramp honors the resolved screenRampCurve (not hardcoded)', () {
    // A region that is purely an exit ramp: enter=0, exit=full duration.
    // The focal lerps rect.center -> video center over the exit. With a
    // linear curve the focal is exactly halfway at the ramp midpoint;
    // with easeInOutQuad it is also 0.5 at the midpoint, so probe at the
    // quarter point where the two curves diverge measurably.
    final region = ZoomRegion(
      rect: const Rect.fromLTRB(0, 0, 400, 400), // center (200,200)
      startTime: Duration.zero,
      duration: const Duration(milliseconds: 1000),
      zoomLevel: 2.0,
      enterDuration: Duration.zero,
      exitDuration: const Duration(milliseconds: 1000),
      followCursor: true,
      followMode: FollowMode.centered,
    );
    final centre = Offset(_videoSize.width / 2, _videoSize.height / 2);

    Offset focalAtQuarter(Curve curve) {
      final c = ZoomFocalController();
      Offset last = Offset.zero;
      // Walk to 250ms (quarter of the 1000ms exit ramp) at 16ms steps,
      // cursor held far from centre so the pre-exit focal != centre.
      for (var ms = 0; ms <= 250; ms += 16) {
        final u = c.update(
          position: Duration(milliseconds: ms),
          zoomRegions: [region],
          cursor: const Offset(1900, 1060),
          videoSize: _videoSize,
          screenRampCurve: curve,
        );
        last = u!.focal;
      }
      return last;
    }

    final linear = focalAtQuarter(Curves.linear);
    final eased = focalAtQuarter(Curves.easeInOutQuad);
    // easeInOutQuad(0.25)=0.125 vs linear 0.25 → different lerp toward
    // centre, so the two focal points must differ.
    expect((linear - eased).distance, greaterThan(1.0),
        reason: 'exit ramp must follow screenRampCurve, not a hardcode');
    expect(linear, isNot(equals(centre)));
  });

  group('enter ramp lock-step', () {
    ZoomRegion enterRegion({
      bool followCursor = true,
      Duration enter = const Duration(milliseconds: 500),
    }) =>
        ZoomRegion(
          rect: const Rect.fromLTRB(0, 0, 400, 400), // center (200,200)
          startTime: Duration.zero,
          duration: const Duration(milliseconds: 3000),
          zoomLevel: 2.0,
          enterDuration: enter,
          exitDuration: Duration.zero,
          followCursor: followCursor,
          followMode: FollowMode.centered,
        );

    Offset walkTo(ZoomFocalController c, ZoomRegion r, int toMs,
        {required Offset cursor, Curve curve = Curves.easeInOutQuad}) {
      Offset last = Offset.zero;
      for (var ms = 0; ms <= toMs; ms += 16) {
        last = c
            .update(
              position: Duration(milliseconds: ms),
              zoomRegions: [r],
              cursor: cursor,
              videoSize: _videoSize,
              screenRampCurve: curve,
            )!
            .focal;
      }
      return last;
    }

    test('focal arrives at the cursor by the end of enterDuration', () {
      final r = enterRegion();
      const cursor = Offset(1700, 950);
      final atEnd =
          walkTo(ZoomFocalController(), r, 500, cursor: cursor);
      // By the end of the 500ms enter ramp the focal should essentially
      // equal the cursor target (the lerp reaches eased(1)=1).
      expect((atEnd - cursor).distance, lessThan(2.0));
    });

    test('halfway through the ramp the focal is between center and cursor',
        () {
      final r = enterRegion();
      const cursor = Offset(1700, 950);
      const centre = Offset(200, 200);
      final mid = walkTo(ZoomFocalController(), r, 250, cursor: cursor);
      // Strictly between the start (rect.center) and the cursor — proves
      // the pan is in progress, not snapped and not still parked.
      expect((mid - centre).distance, greaterThan(2.0));
      expect((mid - cursor).distance, greaterThan(2.0));
    });

    test('followCursor:false makes the enter ramp a no-op (stays center)',
        () {
      final r = enterRegion(followCursor: false);
      const cursor = Offset(1700, 950);
      const centre = Offset(200, 200);
      final mid = walkTo(ZoomFocalController(), r, 250, cursor: cursor);
      expect((mid - centre).distance, lessThan(1.0));
    });

    test('the resolved curve shapes the ramp (linear != easeInOutQuad)',
        () {
      final r = enterRegion();
      const cursor = Offset(1700, 950);
      final lin = walkTo(ZoomFocalController(), r, 250,
          cursor: cursor, curve: Curves.linear);
      final eas = walkTo(ZoomFocalController(), r, 250,
          cursor: cursor, curve: Curves.easeInOutQuad);
      expect((lin - eas).distance, greaterThan(1.0));
    });

    test('hands off from rest — no overshoot past a stationary cursor', () {
      // The focal pans rect.center -> cursor over the 500ms enter ramp,
      // then the spring takes over. With a stationary cursor the focal
      // must never travel FARTHER from the start than the cursor itself;
      // any excursion beyond |cursor - center| is the spring overshooting
      // because the ramp injected residual velocity at handoff.
      final r = enterRegion();
      const cursor = Offset(1700, 950);
      const centre = Offset(200, 200); // rect.center of enterRegion
      final maxReach = (cursor - centre).distance;
      final c = ZoomFocalController();
      var observedMax = 0.0;
      // Walk through the ramp and well into the hold (1000ms total).
      for (var ms = 0; ms <= 1000; ms += 16) {
        final f = c
            .update(
              position: Duration(milliseconds: ms),
              zoomRegions: [r],
              cursor: cursor,
              videoSize: _videoSize,
              screenRampCurve: Curves.easeInOutQuad,
            )!
            .focal;
        final d = (f - centre).distance;
        if (d > observedMax) observedMax = d;
      }
      expect(observedMax, lessThan(maxReach + 1.0),
          reason: 'focal overshot the cursor at the ramp->spring handoff');
    });
  });
}
