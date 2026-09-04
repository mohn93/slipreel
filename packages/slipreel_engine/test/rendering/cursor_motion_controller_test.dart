import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/rendering/cursor_motion_controller.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _record(
  List<({int micros, double x, double y, bool clicked})> samples,
) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(
      CursorPosition(
        x: s.x,
        y: s.y,
        timestampMicros: s.micros,
        isClicked: s.clicked,
      ),
    );
  }
  return r;
}

/// Test-only config that keeps a preset's spring character but pins
/// [feedforwardStrength] to 0 — used to isolate the feedforward
/// CONTRIBUTION (with vs. without) now that the strength comes from
/// the config rather than MotionTuning, so a tuning override alone
/// can no longer disable it.
class _ZeroFeedforwardConfig extends CursorAnimationConfig {
  _ZeroFeedforwardConfig(super.preset) : super.preset();

  @override
  double get feedforwardStrength => 0.0;
}

/// Advance the controller through a sequence of playhead positions
/// (priming, then steady-state). The spring is stateful, so a
/// single one-shot `update()` doesn't exercise the integration step —
/// most tests need a primed history to assert anything meaningful.
CursorMotionUpdate? _drive(
  CursorMotionController ctrl, {
  required CursorRecording rec,
  required CursorAnimationConfig config,
  required List<int> microsTimeline,
  int fps = 60,
}) {
  CursorMotionUpdate? last;
  for (final m in microsTimeline) {
    last = ctrl.update(
      position: Duration(microseconds: m),
      cursorRecording: rec,
      config: config,
      fps: fps,
    );
  }
  return last;
}

void main() {
  group('CursorMotionController (spring)', () {
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

    test('None preset (snap) renders raw recorded position', () {
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

    test(
      'None preset snaps to the nearest sample, not the interpolated value',
      () {
        // Two samples 100 ms apart. Query 60 ms past the first one →
        // the closer sample is at t=100ms (40 ms away), not t=0ms
        // (60 ms away). The linearly-interpolated value at t=60ms is
        // x=60. Snap mode must return x=100 (the nearest sample's
        // value), not x=60.
        final ctrl = CursorMotionController();
        final rec = _record([
          (micros: 0, x: 0, y: 0, clicked: false),
          (micros: 100000, x: 100, y: 0, clicked: false),
        ]);
        final cfg = const CursorAnimationConfig.preset(
          CursorAnimationStyle.none,
        );

        final outLate = ctrl.update(
          position: const Duration(milliseconds: 60),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
        );
        expect(
          outLate!.screenPos.dx,
          closeTo(100, 1e-6),
          reason:
              'Snap mode must pick the closer recorded sample '
              '(t=100ms) over the linearly-interpolated value (60).',
        );

        // Symmetric check: 40 ms in is closer to t=0ms (40 ms away) than
        // to t=100ms (60 ms away), so snap should report x=0.
        final ctrl2 = CursorMotionController();
        final outEarly = ctrl2.update(
          position: const Duration(milliseconds: 40),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
        );
        expect(
          outEarly!.screenPos.dx,
          closeTo(0, 1e-6),
          reason:
              'Snap mode must pick the closer recorded sample '
              '(t=0ms) and not return interpolation (40).',
        );
      },
    );

    test('None preset still removes a single-sample cursor shake', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16000, x: 5, y: 0, clicked: false),
        (micros: 32000, x: 200, y: 0, clicked: false),
        (micros: 48000, x: 15, y: 0, clicked: false),
        (micros: 64000, x: 20, y: 0, clicked: false),
      ]);

      final out = ctrl.update(
        position: const Duration(milliseconds: 32),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
        postProcess: const CursorPostProcess(
          removeShakes: true,
          shakeThresholdPx: 20,
        ),
      );

      expect(
        out!.screenPos.dx,
        closeTo(10, 1e-6),
        reason:
            'Snap mode should keep the nearest sample timestamp while '
            'snapping its spiked coordinates onto the neighbour path '
            '(midpoint of x=5 and x=15).',
      );
    });

    test('None preset preserves the synthetic return-to-start path', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 1000000, x: 100, y: 0, clicked: false),
        (micros: 2000000, x: 200, y: 0, clicked: false),
      ]);
      const config = CursorAnimationConfig.preset(CursorAnimationStyle.none);
      const behavior = CursorPostProcess(loopPosition: true);
      const end = Duration(seconds: 2);

      final middle = ctrl.update(
        position: const Duration(milliseconds: 1500),
        cursorRecording: rec,
        config: config,
        fps: 60,
        postProcess: behavior,
        cursorLoopEnd: end,
      );
      final finish = ctrl.update(
        position: end,
        cursorRecording: rec,
        config: config,
        fps: 60,
        postProcess: behavior,
        cursorLoopEnd: end,
      );

      expect(middle!.screenPos.dx, closeTo(50, 1e-9));
      expect(finish!.screenPos.dx, 0);
    });

    test('first call primes the spring to the raw position', () {
      // The spring is stateful, so the very first call has no prior
      // (x, vx) to integrate from. The controller seeds itself with
      // the raw recorded position — anything else would make the
      // synthetic cursor visibly drift in from (0, 0) on every
      // recording load.
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 200, y: 50, clicked: false),
        (micros: 100000, x: 200, y: 50, clicked: false),
      ]);

      final out = ctrl.update(
        position: const Duration(milliseconds: 50),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out!.screenPos.dx, closeTo(200, 1e-6));
      expect(out.screenPos.dy, closeTo(50, 1e-6));
    });

    test(
      'stationary recording stays at the raw position across primed calls',
      () {
        final ctrl = CursorMotionController();
        final rec = _record(
          List.generate(
            60,
            (i) => (micros: i * 16667, x: 42.0, y: 7.0, clicked: false),
          ),
        );
        final out = _drive(
          ctrl,
          rec: rec,
          config: const CursorAnimationConfig.preset(
            CursorAnimationStyle.smooth,
          ),
          microsTimeline: List.generate(
            30,
            (i) => i * 16667,
          ), // drive 30 frames forward
        );
        expect(out!.screenPos.dx, closeTo(42.0, 1e-6));
        expect(out.screenPos.dy, closeTo(7.0, 1e-6));
      },
    );

    test(
      'idempotent at the same position (no double-step under setState rebuilds)',
      () {
        final ctrl = CursorMotionController();
        final rec = _record([
          (micros: 0, x: 0, y: 0, clicked: false),
          (micros: 100000, x: 200, y: 0, clicked: false),
        ]);
        final cfg = const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth,
        );

        final a = ctrl.update(
          position: const Duration(milliseconds: 50),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
        );
        final b = ctrl.update(
          position: const Duration(milliseconds: 50),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
        );
        expect(b!.screenPos, a!.screenPos);
      },
    );

    test('stiffer spring settles closer to a step\'s new value', () {
      // Step from x=0 to x=100 at t=500 ms. Drive both controllers
      // forward through identical timelines, then sample 150 ms past
      // the step. Stiffer = shorter settle time, so rapid's residual
      // error from the new value (100) is smaller than smooth's. The
      // two springs can land on opposite sides of 100 — the velocity
      // feedforward briefly inflates the chase target after the step
      // discontinuity — so the assertion compares |error|, not signed
      // position.
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 499000, x: 0, y: 0, clicked: false),
        (micros: 500000, x: 100, y: 0, clicked: false),
        (micros: 2000000, x: 100, y: 0, clicked: false),
      ]);
      final timeline = List.generate(40, (i) => i * 16667); // 0..650ms

      final smoothCtrl = CursorMotionController();
      final rapidCtrl = CursorMotionController();
      final smooth = _drive(
        smoothCtrl,
        rec: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        microsTimeline: timeline,
      );
      final rapid = _drive(
        rapidCtrl,
        rec: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
        microsTimeline: timeline,
      );

      final smoothErr = (smooth!.screenPos.dx - 100).abs();
      final rapidErr = (rapid!.screenPos.dx - 100).abs();
      expect(
        rapidErr,
        lessThan(smoothErr),
        reason:
            'Stiffer = shorter settling time. After 150 ms the rapid '
            'spring\'s residual error from the new step value (100) '
            'should be smaller than the smooth spring\'s.',
      );
    });

    test('constant-velocity motion: Medium\'s 50 % feedforward halves the '
        'spring\'s steady-state lag', () {
      // Cursor moves at 1000 px/s along the X-axis. A vanilla causal
      // spring (no feedforward) sits at cursorAt(t − τ), lagging by
      // τ·v ≈ 103 px at the Medium spring (k=380, ζ=1 → τ = 2/√380 s).
      // Medium's 50 % feedforward cancels half of that: ≈ 51 px.
      const dtPerFrameMicros = 16667; // 60 fps
      const velocityPxPerSec = 1000.0;
      final mediumTauSec = 2.0 / math.sqrt(380.0);
      final expectedLag = mediumTauSec * velocityPxPerSec * 0.5; // ~51 px

      final rec = _record(
        List.generate(90, (i) {
          final tMicros = i * dtPerFrameMicros;
          return (
            micros: tMicros,
            x: (tMicros / 1e6) * velocityPxPerSec,
            y: 0.0,
            clicked: false,
          );
        }),
      );
      // Drive ~750 ms — well past 3τ ≈ 308 ms, so the spring is in
      // steady state.
      final timeline = List.generate(45, (i) => i * dtPerFrameMicros);

      final ctrl = CursorMotionController();
      final last = _drive(
        ctrl,
        rec: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.medium),
        microsTimeline: timeline,
      );

      final tMicros = timeline.last;
      final expectedPos = (tMicros / 1e6) * velocityPxPerSec;
      final actualLag = expectedPos - last!.screenPos.dx;
      // ±20 px window absorbs the velocity-lookback transient.
      expect(
        actualLag,
        closeTo(expectedLag, 20),
        reason:
            'With Medium\'s feedforwardStrength = 0.5 the steady-state lag '
            'should be about half the vanilla chase\'s τ·v ≈ 103 px — i.e. '
            '≈ ${expectedLag.toStringAsFixed(0)} px. Got ${actualLag.toStringAsFixed(1)} px.',
      );
    });

    test('presets are contrasted: Smooth trails ≥8× further than Rapid '
        'at constant velocity', () {
      const dtPerFrameMicros = 16667;
      const velocityPxPerSec = 1000.0;
      final rec = _record(
        List.generate(90, (i) {
          final tMicros = i * dtPerFrameMicros;
          return (
            micros: tMicros,
            x: (tMicros / 1e6) * velocityPxPerSec,
            y: 0.0,
            clicked: false,
          );
        }),
      );
      final timeline = List.generate(45, (i) => i * dtPerFrameMicros);

      double lagFor(CursorAnimationStyle style) {
        final ctrl = CursorMotionController();
        final last = _drive(
          ctrl,
          rec: rec,
          config: CursorAnimationConfig.preset(style),
          microsTimeline: timeline,
        );
        final expectedPos = (timeline.last / 1e6) * velocityPxPerSec;
        return expectedPos - last!.screenPos.dx;
      }

      final smoothLag = lagFor(CursorAnimationStyle.smooth);
      final rapidLag = lagFor(CursorAnimationStyle.rapid);
      expect(
        smoothLag,
        greaterThan(rapidLag.abs() * 8),
        reason:
            'The whole point of the redesign: Smooth (soft spring, '
            'weak feedforward) must visibly trail; Rapid (stiff, strong '
            'feedforward) must track near-locked. Smooth lag ≥8× Rapid. '
            'smooth=${smoothLag.toStringAsFixed(1)}px '
            'rapid=${rapidLag.toStringAsFixed(1)}px',
      );
      expect(
        rapidLag.abs(),
        lessThan(5.0),
        reason:
            'Rapid should read as locked (<5px, precision of one cursor '
            'width at 1000 px/s)',
      );
    });

    test('Smooth\'s underdamped spring overshoots a stop; Medium\'s '
        'critically-damped spring overshoots less', () {
      // Constant motion at 1000 px/s that stops dead at x=500, t=500 ms.
      // The underdamped Smooth spring carries momentum through the stop
      // and drifts past the rest point before settling back; Medium
      // (ζ=1) settles monotonically (any tiny excursion comes only from
      // the feedforward-target transient, which its stronger fade-out
      // keeps small). Assert Smooth's peak excursion past the stop
      // exceeds Medium's, and that it stays bounded (a float, not a
      // boomerang).
      const dtPerFrameMicros = 16667;
      final rec = _record(
        List.generate(120, (i) {
          final tMicros = i * dtPerFrameMicros;
          final tSec = tMicros / 1e6;
          final x = tSec < 0.5 ? tSec * 1000.0 : 500.0;
          return (micros: tMicros, x: x, y: 0.0, clicked: false);
        }),
      );
      // Drive to ~1.9 s so even the soft spring fully settles.
      final timeline = List.generate(115, (i) => i * dtPerFrameMicros);

      double maxExcursionFor(CursorAnimationStyle style) {
        final ctrl = CursorMotionController();
        var maxX = double.negativeInfinity;
        for (final micros in timeline) {
          final u = ctrl.update(
            position: Duration(microseconds: micros),
            cursorRecording: rec,
            config: CursorAnimationConfig.preset(style),
            fps: 60,
          );
          if (u != null && u.screenPos.dx > maxX) maxX = u.screenPos.dx;
        }
        return maxX - 500.0;
      }

      final smoothOver = maxExcursionFor(CursorAnimationStyle.smooth);
      final mediumOver = maxExcursionFor(CursorAnimationStyle.medium);
      expect(
        smoothOver,
        greaterThan(mediumOver),
        reason:
            'Underdamped Smooth must drift past the stop point '
            'further than critically-damped Medium. '
            'smooth=${smoothOver.toStringAsFixed(2)}px '
            'medium=${mediumOver.toStringAsFixed(2)}px',
      );
      expect(
        smoothOver,
        lessThan(25.0),
        reason: 'The float must stay tasteful — a drift, not a boomerang.',
      );
    });

    test(
      'backwards scrub resets state so the next forward step has no velocity bleed',
      () {
        // Imagine the cursor was racing across the screen at 1000 px/s.
        // The user scrubs back to the start. If the spring kept its
        // huge prior velocity, the rendered cursor would shoot off in
        // the old direction on the next forward step. The controller
        // resets state on any backward step so that doesn't happen.
        final ctrl = CursorMotionController();
        final rec = _record(
          List.generate(
            60,
            (i) => (micros: i * 16667, x: i * 30.0, y: 0.0, clicked: false),
          ),
        );

        // Prime the spring at high velocity near the end of the
        // recording.
        _drive(
          ctrl,
          rec: rec,
          config: const CursorAnimationConfig.preset(
            CursorAnimationStyle.smooth,
          ),
          microsTimeline: List.generate(40, (i) => i * 16667),
        );

        // Scrub back to t=0. State must reset, so the rendered position
        // equals the (sigma-aware) sample at t=0 — no leftover velocity
        // from the prior high-speed chase. Smooth samples the
        // geometrically-smoothed path (Task 6), so at the very start of
        // the recording the Gaussian window only has forward taps to
        // draw on and the "raw position" is that smoothed value, not the
        // literal recorded x=0 — compute the same way production does.
        final expected = smoothedCursorAt(
          rec,
          Duration.zero,
          CursorPostProcess.none,
          CursorAnimationStyle.smooth.pathSmoothingSigma,
        )!;
        final scrubbed = ctrl.update(
          position: Duration.zero,
          cursorRecording: rec,
          config: const CursorAnimationConfig.preset(
            CursorAnimationStyle.smooth,
          ),
          fps: 60,
        );
        expect(scrubbed!.screenPos.dx, closeTo(expected.x, 1e-6));
      },
    );

    test('click + cursor state come from the rendered timestamp', () {
      // The spring's persistent state is about position, not click
      // flags. Click and cursor-state read directly from
      // cursorAt(position) so a press / release fires at the
      // recorded moment — independent of where the spring's chase
      // currently is.
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 199000, x: 0, y: 0, clicked: false),
        (micros: 200000, x: 0, y: 0, clicked: true),
        (micros: 220000, x: 0, y: 0, clicked: false),
        (micros: 1000000, x: 0, y: 0, clicked: false),
      ]);

      final before = ctrl.update(
        position: const Duration(microseconds: 100000),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(before!.isClicked, isFalse);

      final during = ctrl.update(
        position: const Duration(microseconds: 210000),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(during!.isClicked, isTrue);

      final after = ctrl.update(
        position: const Duration(microseconds: 500000),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(after!.isClicked, isFalse);
    });

    test('reset() drops state so the next call re-primes', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 100, y: 0, clicked: false),
      ]);
      final cfg = const CursorAnimationConfig.preset(
        CursorAnimationStyle.smooth,
      );

      final a = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec,
        config: cfg,
        fps: 60,
      );
      ctrl.reset();
      final b = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec,
        config: cfg,
        fps: 60,
      );
      // Same inputs, same output — but importantly, no exception and
      // the reset path doesn't strand stale velocity.
      expect(b!.screenPos.dx, closeTo(a!.screenPos.dx, 1e-6));
    });

    test('velocity is zero before the back-look window starts', () {
      // Scene velocity = (cursor at T - cursor at T-lookback) / lookback.
      // For T < lookback the back-look falls before t=0, so we have no
      // sample to compare against and report zero.
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16667, x: 30, y: 0, clicked: false),
      ]);
      final out = ctrl.update(
        position: const Duration(microseconds: 16667), // < 33ms lookback
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero);
    });

    test('a single forward call produces a non-zero scene velocity', () {
      // Scene velocity is stateless — the very first call past the
      // lookback window already returns the recorded velocity at that
      // timestamp.
      final ctrl = CursorMotionController();
      final rec = _record(
        List.generate(
          60,
          (i) => (micros: i * 16667, x: i * 30.0, y: 0.0, clicked: false),
        ),
      );
      final out = ctrl.update(
        position: const Duration(microseconds: 50001),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec.dx, closeTo(1800, 30));
      expect(out.velocityPxPerSec.dy, closeTo(0, 1e-6));
    });

    test(
      'backwards scrub still returns scene velocity (direction-agnostic)',
      () {
        final ctrl = CursorMotionController();
        final rec = _record(
          List.generate(
            60,
            (i) => (micros: i * 16667, x: i * 30.0, y: 0.0, clicked: false),
          ),
        );
        ctrl.update(
          position: const Duration(microseconds: 500000),
          cursorRecording: rec,
          config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
          fps: 60,
        );
        final out = ctrl.update(
          position: const Duration(microseconds: 100000),
          cursorRecording: rec,
          config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
          fps: 60,
        );
        expect(out!.velocityPxPerSec.dx, closeTo(1800, 30));
        expect(out.velocityPxPerSec.dy, closeTo(0, 1e-6));
      },
    );

    test('idempotent same-position call returns the same velocity', () {
      final ctrl = CursorMotionController();
      final rec = _record(
        List.generate(
          60,
          (i) => (micros: i * 16667, x: i * 30.0, y: 0.0, clicked: false),
        ),
      );
      final out1 = ctrl.update(
        position: const Duration(microseconds: 50001),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      final out1Again = ctrl.update(
        position: const Duration(microseconds: 50001),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out1Again!.velocityPxPerSec, out1!.velocityPxPerSec);
    });

    test('null-cursor at the back-look returns zero velocity', () {
      final ctrl = CursorMotionController();
      final big = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 1000, y: 0, clicked: false),
      ]);
      final out = ctrl.update(
        position: const Duration(microseconds: 100000),
        cursorRecording: big,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(
        out!.velocityPxPerSec.dx,
        lessThan(11000),
        reason:
            'Velocity must reflect the actual recorded motion, '
            'not a fabricated jump from a missing sample.',
      );
    });

    // A horizontal ramp the spring will lag behind. Samples every 16 ms
    // for 320 ms so there is room to observe steady-state lag.
    CursorRecording ramp() => _record([
      for (int i = 0; i <= 20; i++)
        (micros: i * 16000, x: i * 50.0, y: 0, clicked: false),
    ]);

    test('playbackSpeed defaults to 1.0 → output identical to omitting it', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final rec = ramp();
      final timeline = [for (int i = 0; i <= 20; i++) i * 16000];

      final a = CursorMotionController();
      final b = CursorMotionController();
      CursorMotionUpdate? lastA;
      CursorMotionUpdate? lastB;
      for (final m in timeline) {
        lastA = a.update(
          position: Duration(microseconds: m),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
        );
        lastB = b.update(
          position: Duration(microseconds: m),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
          playbackSpeed: 1.0,
        );
      }
      expect(lastB!.screenPos.dx, closeTo(lastA!.screenPos.dx, 1e-9));
      expect(lastB.screenPos.dy, closeTo(lastA.screenPos.dy, 1e-9));
    });

    test('2× source stepping lags more in source space than 1× (softer)', () {
      // Same recorded ramp, same wall cadence (real frames). The 1× run
      // advances source time 16 ms/frame; the 2× run advances 32 ms/frame
      // (source moves 2× faster per wall frame). At the SAME source
      // position the speed-aware spring must sit further behind the raw
      // path — that extra source-lag is what plays back as preserved
      // wall-time softness.
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final rec = ramp();

      final slow = CursorMotionController();
      CursorMotionUpdate? lastSlow;
      for (int i = 0; i <= 10; i++) {
        lastSlow = slow.update(
          position: Duration(microseconds: i * 16000),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
          playbackSpeed: 1.0,
        );
      }
      // 1× reached source t=160ms.
      final spriteAt160 = lastSlow!.screenPos.dx;

      final fast = CursorMotionController();
      CursorMotionUpdate? lastFast;
      for (int i = 0; i <= 5; i++) {
        lastFast = fast.update(
          position: Duration(microseconds: i * 32000),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
          playbackSpeed: 2.0,
        );
      }
      // 2× also reached source t=160ms (5 frames × 32 ms), but the spring
      // integrated half the effective time per frame → it sits further
      // behind (smaller dx) than the 1× run at the same source t.
      expect(lastFast!.screenPos.dx, lessThan(spriteAt160 - 1.0));
    });

    test('feedforward lead scales with playback speed', () {
      // Feedforward CONTRIBUTION = (sprite with feedforward) − (sprite
      // with feedforward disabled), at the same source position. The
      // lead is scaled by playbackSpeed, so the contribution at 2× must
      // exceed the contribution at 1×. (Without the `× speedFactor`
      // factor the lead is identical at both speeds, and since the 2×
      // run integrates less effective time per source position, its
      // contribution would NOT exceed the 1× contribution.)
      //
      // Strength now comes from the config (per-preset), not tuning, so
      // "feedforward disabled" is a config whose feedforwardStrength is
      // pinned to 0 while keeping Smooth's spring — see
      // [_ZeroFeedforwardConfig] below.
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final noFfCfg = _ZeroFeedforwardConfig(CursorAnimationStyle.smooth);
      // Fast ramp (6250 px/s source) so the feedforward fade is fully on
      // for both speeds — isolates the `× speedFactor` lead factor.
      final rec = _record([
        for (int i = 0; i <= 60; i++)
          (micros: i * 16000, x: i * 100.0, y: 0, clicked: false),
      ]);

      double driveTo({
        required double speed,
        required CursorAnimationConfig config,
      }) {
        final ctrl = CursorMotionController();
        // Step source time in `speed`-sized 16 ms increments so every run
        // reaches the same source position (480 ms), mirroring real
        // playback at that speed.
        final stepMicros = (16000 * speed).round();
        final frames = 480000 ~/ stepMicros;
        CursorMotionUpdate? last;
        for (int i = 0; i <= frames; i++) {
          last = ctrl.update(
            position: Duration(microseconds: i * stepMicros),
            cursorRecording: rec,
            config: config,
            fps: 60,
            playbackSpeed: speed,
          );
        }
        return last!.screenPos.dx;
      }

      // Feedforward fully disabled → pure spring chase baseline.
      final contribution1x =
          driveTo(speed: 1.0, config: cfg) -
          driveTo(speed: 1.0, config: noFfCfg);
      final contribution2x =
          driveTo(speed: 2.0, config: cfg) -
          driveTo(speed: 2.0, config: noFfCfg);

      // Feedforward pulls the sprite forward (toward the raw path)...
      expect(contribution1x, greaterThan(0));
      // ...and that pull scales up with playback speed.
      expect(contribution2x, greaterThan(contribution1x));
    });

    test('feedforward fade keys off perceived (wall) speed', () {
      // Source speed 187.5 px/s is BELOW the fade-start threshold
      // (200 px/s), so at 1× the feedforward is fully faded OFF and
      // contributes nothing. At 2× the PERCEIVED speed (≈375 px/s) is
      // inside the fade band, so keying the fade off perceived speed
      // turns the feedforward back on and its contribution goes
      // positive. (Under the old source-speed fade the 2× run would also
      // see 187.5 px/s and stay off, so this discriminates the change.)
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final noFfCfg = _ZeroFeedforwardConfig(CursorAnimationStyle.smooth);
      // 3 px / 16 ms = 187.5 px/s source speed (< 200 px/s fade-start).
      final rec = _record([
        for (int i = 0; i <= 60; i++)
          (micros: i * 16000, x: i * 3.0, y: 0, clicked: false),
      ]);

      double driveTo({
        required double speed,
        required CursorAnimationConfig config,
      }) {
        final ctrl = CursorMotionController();
        final stepMicros = (16000 * speed).round();
        final frames = 480000 ~/ stepMicros;
        CursorMotionUpdate? last;
        for (int i = 0; i <= frames; i++) {
          last = ctrl.update(
            position: Duration(microseconds: i * stepMicros),
            cursorRecording: rec,
            config: config,
            fps: 60,
            playbackSpeed: speed,
          );
        }
        return last!.screenPos.dx;
      }

      final contribution1x =
          driveTo(speed: 1.0, config: cfg) -
          driveTo(speed: 1.0, config: noFfCfg);
      final contribution2x =
          driveTo(speed: 2.0, config: cfg) -
          driveTo(speed: 2.0, config: noFfCfg);

      // At 1× the sub-threshold source speed keeps the feedforward off.
      expect(contribution1x, closeTo(0, 1e-9));
      // Keying the fade off perceived speed turns it on at 2×.
      expect(contribution2x, greaterThan(1.0));
    });

    test('Smooth keeps high-frequency hand jitter sub-pixel '
        '(geometric path smoothing)', () {
      // ±12 px alternating-sample wiggle around y=100 while x sweeps —
      // the "wiggles with my hand jitter" complaint from the feel
      // session. Medium chases the raw geometry (delayed but intact);
      // Smooth samples the Gaussian-smoothed path, so its rendered
      // y-deviation from the centerline must be a fraction of Medium's.
      const dtPerFrameMicros = 16667;
      final rec = _record([
        for (var i = 0; i <= 120; i++)
          (
            micros: i * dtPerFrameMicros,
            x: i * 8.0,
            y: 100.0 + (i.isEven ? 12.0 : -12.0),
            clicked: false,
          ),
      ]);
      final timeline = List.generate(120, (i) => i * dtPerFrameMicros);

      double peakWiggleFor(CursorAnimationStyle style) {
        final ctrl = CursorMotionController();
        var peak = 0.0;
        for (final micros in timeline) {
          final u = ctrl.update(
            position: Duration(microseconds: micros),
            cursorRecording: rec,
            config: CursorAnimationConfig.preset(style),
            fps: 60,
          );
          // Skip the settle-in half second AND the last ~200ms: near the
          // recording's tail the Gaussian window's (±2σ = 160ms) forward
          // taps all clamp to the LAST sample (getPositionAt clamps, it
          // never nulls), so that one duplicated value is over-weighted
          // and biases the smoothed path (see cursor_path_smoothing_test
          // .dart's own bounded measurement window on the same fixture
          // shape). That boundary artifact isn't what this test is
          // discriminating.
          if (u != null && micros > 500000 && micros < 1800000) {
            final dev = (u.screenPos.dy - 100.0).abs();
            if (dev > peak) peak = dev;
          }
        }
        return peak;
      }

      final smoothPeak = peakWiggleFor(CursorAnimationStyle.smooth);
      final mediumPeak = peakWiggleFor(CursorAnimationStyle.medium);
      expect(
        smoothPeak,
        lessThan(0.1),
        reason:
            'Smooth samples the geometrically smoothed path — its '
            'rendered residual should be visually sub-pixel. '
            'smooth=${smoothPeak.toStringAsFixed(2)}px '
            'medium=${mediumPeak.toStringAsFixed(2)}px',
      );
    });

    test('retains and interpolates the actual emitted spring trajectory', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        for (var i = 0; i <= 30; i++)
          (micros: i * 16000, x: i * 20.0, y: i * 3.0, clicked: false),
      ]);
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final outputs = <Duration, Offset>{};
      for (var i = 0; i <= 20; i++) {
        final t = Duration(microseconds: i * 16000);
        outputs[t] = ctrl
            .update(position: t, cursorRecording: rec, config: cfg, fps: 60)!
            .screenPos;
      }

      const beforeT = Duration(microseconds: 160000);
      const afterT = Duration(microseconds: 176000);
      const halfT = Duration(microseconds: 168000);
      expect(ctrl.positionAt(beforeT), outputs[beforeT]);
      expect(
        ctrl.positionAt(halfT),
        Offset.lerp(outputs[beforeT], outputs[afterT], 0.5),
      );
    });

    test(
      'explicit forward seek clears history instead of fabricating a trail',
      () {
        final ctrl = CursorMotionController();
        final rec = _record([
          (micros: 0, x: 0.0, y: 0.0, clicked: false),
          (micros: 5000000, x: 500.0, y: 0.0, clicked: false),
        ]);
        const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
        ctrl.update(
          position: Duration.zero,
          cursorRecording: rec,
          config: cfg,
          fps: 60,
        );
        final sought = ctrl.update(
          position: const Duration(seconds: 5),
          cursorRecording: rec,
          config: cfg,
          fps: 60,
          forceSnap: true,
        )!;

        expect(sought.screenPos.dx, closeTo(500, 1e-9));
        expect(ctrl.positionAt(const Duration(milliseconds: 4950)), isNull);
      },
    );

    test('same-position delay and recording mutations re-prime trajectory', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0.0, y: 0.0, clicked: false),
        (micros: 500000, x: 500.0, y: 0.0, clicked: false),
      ]);
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.medium);
      final current = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec,
        config: cfg,
        fps: 60,
      )!;
      final delayed = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec,
        config: cfg,
        fps: 60,
        cursorDelay: const Duration(milliseconds: 200),
      )!;
      expect(current.screenPos.dx, closeTo(500, 1e-9));
      expect(delayed.screenPos.dx, closeTo(300, 1e-9));

      rec.clear();
      rec.addPosition(CursorPosition(x: 42, y: 7, timestampMicros: 0));
      rec.addPosition(CursorPosition(x: 42, y: 7, timestampMicros: 500000));
      final mutated = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec,
        config: cfg,
        fps: 60,
        cursorDelay: const Duration(milliseconds: 200),
      )!;
      expect(mutated.screenPos, const Offset(42, 7));
    });

    test('same-position trim-bound changes invalidate the smoothed path', () {
      final rec = CursorRecording();
      for (var i = 0; i <= 100; i++) {
        rec.addPosition(
          CursorPosition(
            x: i * 5,
            y: i == 50 ? 112 : 100,
            timestampMicros: i * 10000,
          ),
        );
      }
      final ctrl = CursorMotionController();
      const config = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final unbounded = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec,
        config: config,
        fps: 60,
      )!;
      final trimmed = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec,
        config: config,
        fps: 60,
        clipStart: const Duration(milliseconds: 500),
        clipEnd: const Duration(seconds: 1),
      )!;

      expect((unbounded.screenPos.dy - 100).abs(), lessThan(4));
      expect(trimmed.screenPos.dy, closeTo(112, 1e-9));
    });
  });
}
