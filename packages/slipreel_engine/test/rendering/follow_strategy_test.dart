import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/follow_strategy.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';

const Size _videoSize = Size(1920, 1080);

ZoomRegion _bounded({
  Rect rect = const Rect.fromLTRB(0, 0, 0, 0),
  double zoomLevel = 2.0,
  double deadzoneRatio = 0.4,
  bool followCursor = true,
}) {
  return ZoomRegion(
    rect: rect,
    startTime: Duration.zero,
    duration: const Duration(seconds: 2),
    zoomLevel: zoomLevel,
    deadzoneRatio: deadzoneRatio,
    followCursor: followCursor,
    followMode: FollowMode.bounded,
  );
}

ZoomRegion _predictive({
  double deadzoneRatio = 0.4,
  Duration lead = const Duration(milliseconds: 150),
}) {
  return ZoomRegion(
    rect: const Rect.fromLTRB(0, 0, 0, 0),
    startTime: Duration.zero,
    duration: const Duration(seconds: 2),
    zoomLevel: 2.0,
    deadzoneRatio: deadzoneRatio,
    followCursor: true,
    followMode: FollowMode.predictive,
    predictiveWindow: lead,
  );
}

ZoomRegion _centered({bool followCursor = true}) {
  return ZoomRegion(
    rect: const Rect.fromLTRB(0, 0, 0, 0),
    startTime: Duration.zero,
    duration: const Duration(seconds: 2),
    zoomLevel: 2.0,
    deadzoneRatio: 0,
    followCursor: followCursor,
    followMode: FollowMode.centered,
  );
}

void main() {
  group('CenteredFollowStrategy', () {
    final s = CenteredFollowStrategy();

    test(
      'with followCursor=false returns the zoom rect centre as the target',
      () {
        final r = s.resolve(
          zoom: _centered(followCursor: false),
          cursor: const Offset(500, 500),
          cursorVelocity: Offset.zero,
          currentFocal: const Offset(960, 540),
          videoSize: _videoSize,
          tuning: MotionTuning.defaults,
        );
        expect(r.target, _centered().rect.center);
        expect(r.isHolding, isFalse);
      },
    );

    test(
      'with cursor=null returns video center, holding when already there',
      () {
        final r = s.resolve(
          zoom: _centered(),
          cursor: null,
          cursorVelocity: Offset.zero,
          currentFocal: const Offset(960, 540),
          videoSize: _videoSize,
          tuning: MotionTuning.defaults,
        );
        expect(r.target, const Offset(960, 540));
        expect(r.isHolding, isTrue);
      },
    );

    test('with cursor set returns the cursor as the chase target', () {
      final r = s.resolve(
        zoom: _centered(),
        cursor: const Offset(800, 400),
        cursorVelocity: const Offset(200, 0),
        currentFocal: const Offset(960, 540),
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.target, const Offset(800, 400));
      expect(
        r.isHolding,
        isFalse,
        reason:
            'Cursor at a different position from the focal means the '
            'spring should be chasing, not holding',
      );
    });
  });

  group('BoundedFollowStrategy gate semantics', () {
    test('with followCursor=false collapses to rect centre target', () {
      final s = BoundedFollowStrategy();
      final r = s.resolve(
        zoom: _bounded(followCursor: false),
        cursor: const Offset(800, 400),
        cursorVelocity: Offset.zero,
        currentFocal: const Offset(960, 540),
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.target, _bounded().rect.center);
      expect(r.isHolding, isFalse);
      expect(s.inFlight, isFalse);
    });

    test('engagement is strictly positional: cursor inside dz with zero '
        'velocity keeps the focal pinned (no chase from hover-noise)', () {
      final s = BoundedFollowStrategy();
      final focal = const Offset(960, 540);
      // 1920/2 * 0.4 = 384 px wide deadzone; cursor 100 px from focal
      // is well inside it.
      final r = s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(100, 0),
        cursorVelocity: Offset.zero,
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(
        r.target,
        focal,
        reason:
            'Pin focal in place when cursor is inside the deadzone '
            'and we are not currently chasing',
      );
      expect(r.isHolding, isTrue);
      expect(s.inFlight, isFalse);
    });

    test(
      'engagement: cursor crossing the deadzone boundary starts a chase',
      () {
        final s = BoundedFollowStrategy();
        final focal = const Offset(960, 540);
        // Deadzone half-width = 1920/2 * 0.4 / 2 = 192. Cursor at +400
        // is well outside.
        final r = s.resolve(
          zoom: _bounded(),
          cursor: focal + const Offset(400, 0),
          cursorVelocity: Offset.zero,
          currentFocal: focal,
          videoSize: _videoSize,
          tuning: MotionTuning.defaults,
        );
        expect(r.target, focal + const Offset(400, 0));
        expect(r.isHolding, isFalse);
        expect(s.inFlight, isTrue);
      },
    );

    test('in-flight, cursor moving fast inside the deadzone keeps the gate '
        'engaged (no flap during continuous motion)', () {
      // Prime: engage the gate.
      final s = BoundedFollowStrategy();
      final focal = const Offset(960, 540);
      s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(400, 0),
        cursorVelocity: Offset.zero,
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(s.inFlight, isTrue);

      // Cursor has caught up — now inside dz, but still moving fast.
      // Gate must NOT release (velocity above the at-rest threshold).
      final r = s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(50, 0),
        cursorVelocity: const Offset(500, 0),
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.isHolding, isFalse);
      expect(s.inFlight, isTrue);
    });

    test('release: in-flight cursor inside dz with velocity below threshold '
        'flips the gate to released (cursor has stopped)', () {
      final s = BoundedFollowStrategy();
      final focal = const Offset(960, 540);
      // Engage.
      s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(400, 0),
        cursorVelocity: Offset.zero,
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      // Release condition: inside dz + velocity below 80 px/s.
      final r = s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(30, 0),
        cursorVelocity: const Offset(20, 0),
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(
        r.target,
        focal,
        reason: 'On release the target collapses to currentFocal',
      );
      expect(r.isHolding, isTrue);
      expect(s.inFlight, isFalse);
    });

    test('reset() clears the gate state', () {
      final s = BoundedFollowStrategy();
      final focal = const Offset(960, 540);
      // Engage.
      s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(400, 0),
        cursorVelocity: Offset.zero,
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(s.inFlight, isTrue);
      s.reset();
      expect(s.inFlight, isFalse);
    });

    test('custom tuning: a higher cursorAtRest threshold releases the gate '
        'at speeds the default would keep engaged', () {
      const lenient = MotionTuning(cursorAtRestPxPerSec: 1000.0);
      final s = BoundedFollowStrategy();
      final focal = const Offset(960, 540);
      // Engage.
      s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(400, 0),
        cursorVelocity: Offset.zero,
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: lenient,
      );
      // Velocity 500 px/s is far above the 80 px/s default threshold,
      // but lenient's 1000 px/s lets it release.
      final r = s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(30, 0),
        cursorVelocity: const Offset(500, 0),
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: lenient,
      );
      expect(
        r.isHolding,
        isTrue,
        reason:
            'A higher at-rest threshold accepts a faster cursor as '
            '"at rest"',
      );
      expect(s.inFlight, isFalse);
    });
  });

  group('PredictiveFollowStrategy anticipation', () {
    test('zero velocity behaves like bounded: inside dz holds', () {
      final s = PredictiveFollowStrategy();
      final focal = const Offset(960, 540);
      // dz half-width = 1920/2 * 0.4 / 2 = 192; cursor +100 is inside.
      final r = s.resolve(
        zoom: _predictive(),
        cursor: focal + const Offset(100, 0),
        cursorVelocity: Offset.zero,
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.isHolding, isTrue);
      expect(s.inFlight, isFalse);
    });

    test('velocity lead engages the chase earlier than the raw cursor would',
        () {
      final s = PredictiveFollowStrategy();
      final focal = const Offset(960, 540);
      // Cursor still inside dz (+150 < 192 half-width) but moving fast right.
      // Lead = 0.15s * 500px/s = +75 => aim at +225, outside the dz.
      final r = s.resolve(
        zoom: _predictive(),
        cursor: focal + const Offset(150, 0),
        cursorVelocity: const Offset(500, 0),
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.isHolding, isFalse,
          reason: 'anticipated position is past the deadzone edge');
      expect(s.inFlight, isTrue);
      expect(r.target.dx, closeTo(focal.dx + 225, 0.5),
          reason: 'target is the velocity-led cursor');
    });

    test('bounded with the same cursor/velocity still holds (no lead)', () {
      final s = BoundedFollowStrategy();
      final focal = const Offset(960, 540);
      final r = s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(150, 0),
        cursorVelocity: const Offset(500, 0),
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.isHolding, isTrue,
          reason: 'bounded aims at the raw cursor (+150, inside dz)');
    });
  });
}
