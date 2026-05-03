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
  });
}

// Compile-time-constant bezier for the custom test above.
abstract class CubicBezierCurveDummy {
  static const testCurve =
      CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0);
}
