import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/ui/widgets/zoom/cursor_motion_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _record(
    List<({int micros, double x, double y, bool clicked})> samples) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(CursorPosition(
      x: s.x, y: s.y, timestampMicros: s.micros, isClicked: s.clicked,
    ));
  }
  return r;
}

void main() {
  group('CursorMotionController (FIR)', () {
    test('returns null when there is no cursor data', () {
      final ctrl = CursorMotionController();
      final out = ctrl.update(
        position: const Duration(milliseconds: 50),
        cursorRecording: _record([]),
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out, isNull);
    });

    test('window=0 (None preset) bypasses FIR and returns raw sample', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16000, x: 100, y: 0, clicked: false),
      ]);

      final out = ctrl.update(
        position: const Duration(milliseconds: 16),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.screenPos.dx, closeTo(100, 1e-6));
    });

    test('FIR weights sum to 1 (rendered position lies on the path)', () {
      final ctrl = CursorMotionController();
      // Stationary target. FIR average must equal the constant value.
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667, x: 42.0, y: 7.0, clicked: false,
          )));
      final out = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out!.screenPos.dx, closeTo(42.0, 1e-3));
      expect(out.screenPos.dy, closeTo(7.0, 1e-3));
    });

    test('idempotent at the same position', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 200, y: 0, clicked: false),
      ]);
      final cfg = const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth);

      final a = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      final b = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      expect(b!.screenPos, a!.screenPos);
    });

    test('near start of recording, taps before t=0 clamp to first sample', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 50, y: 50, clicked: false),
        (micros: 1000000, x: 50, y: 50, clicked: false),
      ]);
      // Position at t=0 with a 450 ms window — most taps would land
      // before t=0; they must clamp to the first sample (50,50), not
      // throw.
      final out = ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out, isNotNull);
      expect(out!.screenPos.dx, closeTo(50, 1e-3));
      expect(out.screenPos.dy, closeTo(50, 1e-3));
    });

    test('changing config invalidates the kernel cache', () {
      final ctrl = CursorMotionController();
      // Step from 0 to 100 at t=500ms.
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 499000, x: 0, y: 0, clicked: false),
        (micros: 500000, x: 100, y: 0, clicked: false),
        (micros: 1000000, x: 100, y: 0, clicked: false),
      ]);

      final smooth = ctrl.update(
        position: const Duration(milliseconds: 750),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      final rapid = ctrl.update(
        position: const Duration(milliseconds: 750),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
        fps: 60,
      );
      // Rapid has a much shorter window, so by 250 ms past the step it
      // should be much closer to the new value (100) than smooth.
      expect(rapid!.screenPos.dx, greaterThan(smooth!.screenPos.dx));
    });

    test('easeOut kernel produces ease-out response after a step (fast start, slow settle)',
        () {
      // Step from 0 → 100 at t=500ms, sample shortly after the step.
      // With a 450 ms easeOutCubic window ("smooth"), after ~25% of the
      // window the cursor should already be well past 25% of the way to
      // the target — that's the defining feature of an ease-out
      // response (fast initial movement). A bug we hit once: the kernel
      // got reversed, producing ease-IN behavior (slow start, sudden
      // snap), which felt like "the cursor catches up faster the
      // bigger the window" because nothing happened until the very
      // end. Lock the orientation in.
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 499000, x: 0, y: 0, clicked: false),
        (micros: 500000, x: 100, y: 0, clicked: false),
        (micros: 2000000, x: 100, y: 0, clicked: false),
      ]);

      // Smooth window = 450 ms. 100 ms into the step ≈ 22% of W.
      // ease-out: response ≈ 1 - (1 - 0.22)^3 ≈ 0.53 → ~53.
      // ease-in (the bug): response ≈ 0.22^3 ≈ 0.01 → ~1.
      final out = ctrl.update(
        position: const Duration(milliseconds: 600),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out!.screenPos.dx, greaterThan(40),
          reason: 'easeOut FIR must move >40% of the way after ~22% of the '
              'window; values near 0 mean the kernel is reversed (ease-in).');
    });

    test('reset() clears the cache so the next update recomputes', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 100, y: 0, clicked: false),
      ]);
      final cfg = const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth);

      final a = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      ctrl.reset();
      final b = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      // Same inputs → same output, but importantly no exception.
      expect(b!.screenPos, a!.screenPos);
    });

    test('custom curve evaluates without throwing and returns finite Offset',
        () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 1000000, x: 200, y: 100, clicked: false),
      ]);
      final cfg = CursorAnimationConfig.custom(
        curve: CubicBezierCurveDummy.testCurve,
        window: const Duration(milliseconds: 300),
      );
      final out = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      expect(out!.screenPos.dx.isFinite, isTrue);
      expect(out.screenPos.dy.isFinite, isTrue);
    });

    test('velocityPxPerSec is zero on the first call', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16667, x: 30, y: 0, clicked: false),
      ]);
      final out = ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero);
    });

    test('two forward updates produce a non-zero velocity along the path', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      // First call seeds the controller.
      ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      // Second call — None preset bypasses FIR so velocity is exactly
      // (Δx / Δt) on the raw samples: 30 px / 16.667 ms ≈ 1800 px/s.
      final out = ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec.dx, closeTo(1800, 5));
      expect(out.velocityPxPerSec.dy, closeTo(0, 1e-6));
    });

    test('backwards scrub returns zero velocity', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      ctrl.update(
        position: const Duration(microseconds: 50000),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      final out = ctrl.update(
        position: const Duration(microseconds: 16667), // earlier
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero);
    });

    test('reset clears velocity history — first call after reset returns zero', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      ctrl.reset();
      final out = ctrl.update(
        position: const Duration(microseconds: 50000),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero);
    });

    test('idempotent same-position call returns the same velocity (no state advance)', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      final out1 = ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      final out1Again = ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out1Again!.velocityPxPerSec, out1!.velocityPxPerSec);
      // Stepping forward from here should compute against frame 33334,
      // NOT against the duplicate call. If state had advanced on the
      // duplicate, dt would be 0 here.
      final out2 = ctrl.update(
        position: const Duration(microseconds: 50001),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out2!.velocityPxPerSec.dx, closeTo(1800, 5));
    });

    test('null-cursor gap re-anchors velocity — first non-null frame returns zero', () {
      // Recording covers t=[0..16667us] only. Calls at later positions
      // produce null because there's no sample to read.
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
      ]);
      // Seed: returns the single sample (snap path) and anchors velocity state.
      ctrl.update(
        position: const Duration(microseconds: 0),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      // Long gap with empty recording → cursorAt returns null at far-future
      // positions. (cursorAt's exact behavior is library-defined; if your
      // recording yields a sample even past its last entry, this test still
      // passes because the next step's velocity is computed from a tiny
      // displacement, not a fabricated jump. The IMPORTANT assertion is the
      // final one.)
      final big = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 1000, y: 0, clicked: false),
      ]);
      // Skip the gap: first call after seeding uses a NEW recording where
      // the next sample lives 100ms / 1000px away from the seed. If the
      // velocity tracker had stale anchors from the seed (t=0, x=0), it
      // would compute v ≈ 1000 / 0.1 = 10000 px/s on the very first call
      // with the new recording — but a forward-time NEW recording must
      // ALSO be treated as the start of a new run. To make this test
      // deterministic without depending on cursorAt's empty-window
      // behavior, force a null-producing call between the two rather
      // than relying on `rec`'s out-of-range behavior.
      ctrl.update(
        position: const Duration(microseconds: 50000),
        cursorRecording: _record([]), // empty → cursorAt returns null
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      // Now feed a non-null sample at t=100ms with x=1000. Without the fix
      // (Site A clearing _velPrev*), velocity = (1000 - 0) / (100000us)
      // = 10000 px/s — a huge spike. With the fix, the previous frame's
      // null return cleared the anchors, so this is treated as a first
      // call and velocity = Offset.zero.
      final out = ctrl.update(
        position: const Duration(microseconds: 100000),
        cursorRecording: big,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero,
          reason: 'After a null-cursor gap, velocity must NOT spike on the '
              'first resumed frame.');
    });

    test('FIR path also exposes velocity from the smoothed position', () {
      final ctrl = CursorMotionController();
      // Constant-velocity step: 30 px per 16.667 ms frame, so the
      // smoothed velocity should converge near 1800 px/s.
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      // Step the FIR-smoothed controller several times so the kernel
      // is fully primed (no cold-start under-weighting).
      for (var t = 0; t < 30; t++) {
        ctrl.update(
          position: Duration(microseconds: t * 16667),
          cursorRecording: rec,
          config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
          fps: 60,
        );
      }
      final out = ctrl.update(
        position: const Duration(microseconds: 30 * 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      // FIR introduces lag, so the smoothed velocity may be slightly
      // below the raw 1800. Generous tolerance — we just want to
      // confirm it's non-zero, directionally correct, and in the right
      // ballpark (not the spike scale).
      expect(out!.velocityPxPerSec.dx, greaterThan(500));
      expect(out.velocityPxPerSec.dx, lessThan(2200));
      expect(out.velocityPxPerSec.dy, closeTo(0, 1e-3));
    });
  });
}

// Compile-time-constant bezier for the custom test above.
abstract class CubicBezierCurveDummy {
  static const testCurve =
      CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0);
}
