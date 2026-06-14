import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_motion_controller.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
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

    test('None preset snaps to the nearest sample, not the interpolated value',
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
      final cfg =
          const CursorAnimationConfig.preset(CursorAnimationStyle.none);

      final outLate = ctrl.update(
        position: const Duration(milliseconds: 60),
        cursorRecording: rec,
        config: cfg,
        fps: 60,
      );
      expect(outLate!.screenPos.dx, closeTo(100, 1e-6),
          reason: 'Snap mode must pick the closer recorded sample '
              '(t=100ms) over the linearly-interpolated value (60).');

      // Symmetric check: 40 ms in is closer to t=0ms (40 ms away) than
      // to t=100ms (60 ms away), so snap should report x=0.
      final ctrl2 = CursorMotionController();
      final outEarly = ctrl2.update(
        position: const Duration(milliseconds: 40),
        cursorRecording: rec,
        config: cfg,
        fps: 60,
      );
      expect(outEarly!.screenPos.dx, closeTo(0, 1e-6),
          reason: 'Snap mode must pick the closer recorded sample '
              '(t=0ms) and not return interpolation (40).');
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

    test('stationary recording stays at the raw position across primed calls',
        () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667, x: 42.0, y: 7.0, clicked: false,
          )));
      final out = _drive(
        ctrl,
        rec: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        microsTimeline:
            List.generate(30, (i) => i * 16667), // drive 30 frames forward
      );
      expect(out!.screenPos.dx, closeTo(42.0, 1e-6));
      expect(out.screenPos.dy, closeTo(7.0, 1e-6));
    });

    test('idempotent at the same position (no double-step under setState rebuilds)',
        () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 200, y: 0, clicked: false),
      ]);
      final cfg =
          const CursorAnimationConfig.preset(CursorAnimationStyle.smooth);

      final a = ctrl.update(
        position: const Duration(milliseconds: 50),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      final b = ctrl.update(
        position: const Duration(milliseconds: 50),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      expect(b!.screenPos, a!.screenPos);
    });

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
      final smooth = _drive(smoothCtrl,
          rec: rec,
          config: const CursorAnimationConfig.preset(
              CursorAnimationStyle.smooth),
          microsTimeline: timeline);
      final rapid = _drive(rapidCtrl,
          rec: rec,
          config: const CursorAnimationConfig.preset(
              CursorAnimationStyle.rapid),
          microsTimeline: timeline);

      final smoothErr = (smooth!.screenPos.dx - 100).abs();
      final rapidErr = (rapid!.screenPos.dx - 100).abs();
      expect(rapidErr, lessThan(smoothErr),
          reason:
              'Stiffer = shorter settling time. After 150 ms the rapid '
              'spring\'s residual error from the new step value (100) '
              'should be smaller than the smooth spring\'s.');
    });

    test('constant-velocity motion: partial feedforward halves the '
        'spring\'s steady-state lag', () {
      // Cursor moves at 1000 px/s along the X-axis. A vanilla causal
      // spring (no feedforward) would sit at cursorAt(t − τ), lagging
      // by τ·v ≈ 149 px at the Smooth defaults. The controller's 50 %
      // feedforward cancels half of that lag; the spring should settle
      // ~75 px behind the recorded path.
      const dtPerFrameMicros = 16667; // 60 fps
      const velocityPxPerSec = 1000.0;
      const smoothTauSec = 2.0 / 13.4164; // 2ζ/√k for k=180, ζ=1
      const expectedLag = smoothTauSec * velocityPxPerSec * 0.5; // ~75 px

      final rec = _record(List.generate(90, (i) {
        final tMicros = i * dtPerFrameMicros;
        return (
          micros: tMicros,
          x: (tMicros / 1e6) * velocityPxPerSec,
          y: 0.0,
          clicked: false,
        );
      }));
      // Drive ~700 ms — long enough that 3τ ≈ 450 ms (Smooth) is done
      // and the spring is in steady state.
      final timeline = List.generate(45, (i) => i * dtPerFrameMicros);

      final ctrl = CursorMotionController();
      final last = _drive(
        ctrl,
        rec: rec,
        config:
            const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        microsTimeline: timeline,
      );

      final tMicros = timeline.last;
      final expectedPos = (tMicros / 1e6) * velocityPxPerSec;
      final actualLag = expectedPos - last!.screenPos.dx;
      // 50 % feedforward → lag ≈ τ·v/2. Allow a ±20 px window around
      // the analytical value to absorb the velocity-step transient
      // from the lookback's hard cutoff at t = 33 ms.
      expect(
        actualLag,
        closeTo(expectedLag, 20),
        reason:
            'With _feedforwardStrength = 0.5 the steady-state lag should be '
            'about half the vanilla spring chase\'s τ·v ≈ 149 px — i.e. '
            '≈ ${expectedLag.toStringAsFixed(0)} px. Got ${actualLag.toStringAsFixed(1)} px.',
      );
    });

    test('backwards scrub resets state so the next forward step has no velocity bleed',
        () {
      // Imagine the cursor was racing across the screen at 1000 px/s.
      // The user scrubs back to the start. If the spring kept its
      // huge prior velocity, the rendered cursor would shoot off in
      // the old direction on the next forward step. The controller
      // resets state on any backward step so that doesn't happen.
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));

      // Prime the spring at high velocity near the end of the
      // recording.
      _drive(
        ctrl,
        rec: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        microsTimeline: List.generate(40, (i) => i * 16667),
      );

      // Scrub back to t=0. State must reset, so the rendered position
      // equals the raw position (x=0) — no leftover velocity.
      final scrubbed = ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(scrubbed!.screenPos.dx, closeTo(0, 1e-6));
    });

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
      final cfg =
          const CursorAnimationConfig.preset(CursorAnimationStyle.smooth);

      final a = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      ctrl.reset();
      final b = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
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
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      final out = ctrl.update(
        position: const Duration(microseconds: 50001),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec.dx, closeTo(1800, 30));
      expect(out.velocityPxPerSec.dy, closeTo(0, 1e-6));
    });

    test('backwards scrub still returns scene velocity (direction-agnostic)',
        () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
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
    });

    test('idempotent same-position call returns the same velocity', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
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
      expect(out!.velocityPxPerSec.dx, lessThan(11000),
          reason: 'Velocity must reflect the actual recorded motion, '
              'not a fabricated jump from a missing sample.');
    });

    // A horizontal ramp the spring will lag behind. Samples every 16 ms
    // for 320 ms so there is room to observe steady-state lag.
    CursorRecording _ramp() => _record([
          for (int i = 0; i <= 20; i++)
            (micros: i * 16000, x: i * 50.0, y: 0, clicked: false),
        ]);

    test('playbackSpeed defaults to 1.0 → output identical to omitting it', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final rec = _ramp();
      final timeline = [for (int i = 0; i <= 20; i++) i * 16000];

      final a = CursorMotionController();
      final b = CursorMotionController();
      CursorMotionUpdate? lastA;
      CursorMotionUpdate? lastB;
      for (final m in timeline) {
        lastA = a.update(
            position: Duration(microseconds: m),
            cursorRecording: rec, config: cfg, fps: 60);
        lastB = b.update(
            position: Duration(microseconds: m),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 1.0);
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
      final rec = _ramp();

      final slow = CursorMotionController();
      CursorMotionUpdate? lastSlow;
      for (int i = 0; i <= 10; i++) {
        lastSlow = slow.update(
            position: Duration(microseconds: i * 16000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 1.0);
      }
      // 1× reached source t=160ms.
      final spriteAt160 = lastSlow!.screenPos.dx;

      final fast = CursorMotionController();
      CursorMotionUpdate? lastFast;
      for (int i = 0; i <= 5; i++) {
        lastFast = fast.update(
            position: Duration(microseconds: i * 32000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 2.0);
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
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      // Fast ramp (6250 px/s source) so the feedforward fade is fully on
      // for both speeds — isolates the `× speedFactor` lead factor.
      final rec = _record([
        for (int i = 0; i <= 60; i++)
          (micros: i * 16000, x: i * 100.0, y: 0, clicked: false),
      ]);

      double driveTo({required double speed, required MotionTuning tuning}) {
        final ctrl = CursorMotionController(tuning: tuning);
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
              config: cfg,
              fps: 60,
              playbackSpeed: speed);
        }
        return last!.screenPos.dx;
      }

      // Feedforward fully disabled → pure spring chase baseline.
      const noFf = MotionTuning(cursorFeedforwardStrength: 0.0);
      final contribution1x = driveTo(speed: 1.0, tuning: MotionTuning.defaults) -
          driveTo(speed: 1.0, tuning: noFf);
      final contribution2x = driveTo(speed: 2.0, tuning: MotionTuning.defaults) -
          driveTo(speed: 2.0, tuning: noFf);

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
      // 3 px / 16 ms = 187.5 px/s source speed (< 200 px/s fade-start).
      final rec = _record([
        for (int i = 0; i <= 60; i++)
          (micros: i * 16000, x: i * 3.0, y: 0, clicked: false),
      ]);

      double driveTo({required double speed, required MotionTuning tuning}) {
        final ctrl = CursorMotionController(tuning: tuning);
        final stepMicros = (16000 * speed).round();
        final frames = 480000 ~/ stepMicros;
        CursorMotionUpdate? last;
        for (int i = 0; i <= frames; i++) {
          last = ctrl.update(
              position: Duration(microseconds: i * stepMicros),
              cursorRecording: rec,
              config: cfg,
              fps: 60,
              playbackSpeed: speed);
        }
        return last!.screenPos.dx;
      }

      const noFf = MotionTuning(cursorFeedforwardStrength: 0.0);
      final contribution1x = driveTo(speed: 1.0, tuning: MotionTuning.defaults) -
          driveTo(speed: 1.0, tuning: noFf);
      final contribution2x = driveTo(speed: 2.0, tuning: MotionTuning.defaults) -
          driveTo(speed: 2.0, tuning: noFf);

      // At 1× the sub-threshold source speed keeps the feedforward off.
      expect(contribution1x, closeTo(0, 1e-9));
      // Keying the fade off perceived speed turns it on at 2×.
      expect(contribution2x, greaterThan(1.0));
    });
  });
}
