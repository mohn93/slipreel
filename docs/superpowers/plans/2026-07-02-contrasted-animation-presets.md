# Contrasted Animation Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Animation tab's cursor presets (Smooth/Medium/Rapid/None) and screen presets (Focused/Smooth) recognizably different in a blind A/B — distinct motion character, not just distinct delay.

**Architecture:** Constants-only re-tune plus one small API move. Each `CursorAnimationStyle` gains its own feedforward strength (new getter, exposed via `CursorAnimationConfig`), and `CursorMotionController` reads the strength from the config instead of the global `MotionTuning`. Cursor presets get per-preset stiffness+damping (Smooth becomes underdamped/floaty, Rapid near-locked); screen presets get opposite curve shapes and a wider duration spread. Dead `smoothing` getter removed. No new statefulness — preview==export unaffected.

**Tech Stack:** Dart / Flutter, melos monorepo. Engine package `slipreel_engine` (all changes), `screen_recorder` only re-verified. Tests via `fvm flutter test` per package.

## Global Constraints

- **Preview == export:** constants only; the sprite spring's integration/reset semantics must not change. No new state.
- **Preset count, names, and JSON unchanged** (`toJson`/`fromJson` serialize preset names; the legacy FIR table stays for round-trip).
- **Medium stays exactly today's feel:** `MotionSpring(stiffness: 380, damping: 1.0)`, feedforward 0.5 — it is the unchanged reference.
- **None stays the raw-grid snap** (`MotionSpring.snap`); its feedforward value is irrelevant (snap path bypasses it) but define it as 0.0.
- Exact new cursor values: Smooth `stiffness: 90, damping: 0.8`, ff `0.25`; Rapid `stiffness: 1400, damping: 1.0`, ff `0.85`.
- Exact new screen values: Focused `rampDurationScale 0.5`, `rampCurve Cubic(0.2, 0.0, 0.0, 1.0)`, `badgeDuration 140ms`; Smooth `1.7`, `Cubic(0.65, 0.0, 0.35, 1.0)`, `600ms`. Badge curves unchanged.
- The feedforward **fade band stays global** in `MotionTuning` (200–800 px/s); only the *strength* read moves to the preset. `MotionTuning.cursorFeedforwardStrength` keeps existing (debug variants reference it) but production stops reading it.
- **Do NOT run `dart format`** (pinned formatter reflows unrelated lines). Match surrounding style by hand; verify via analyze + tests.

---

### Task 1: Cursor preset constants + `feedforwardStrength` API + dead-code removal

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/animation_style.dart:73-146` (the `CursorAnimationStyle` enum + extension)
- Modify: `packages/slipreel_engine/lib/rendering/animation_config.dart:45-87` (`CursorAnimationConfig`)
- Test: `packages/slipreel_engine/test/rendering/animation_style_test.dart` (create)

**Interfaces:**
- Consumes: existing `MotionSpring{stiffness, damping (RATIO), mass=1}` from `spring_config.dart`.
- Produces (Task 2 relies on these exact names):
  - `CursorAnimationStyleData.feedforwardStrength` → `double` (0.25 / 0.5 / 0.85 / 0.0)
  - `CursorAnimationConfig.feedforwardStrength` → `double` (delegates to the preset)
  - `CursorAnimationStyleData.smoothing` is **deleted** (verified: zero references repo-wide).

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/rendering/animation_style_test.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';

void main() {
  group('CursorAnimationStyle presets', () {
    // Analytical phase lag of each preset's spring: τ = 2ζ·√(m/k).
    double tau(CursorAnimationStyle s) {
      final spring = s.motionSpring;
      return 2.0 *
          spring.damping *
          math.sqrt(spring.mass / spring.stiffness);
    }

    // What the viewer actually sees during motion: the feedforward
    // cancels `feedforwardStrength` of τ, leaving τ·(1−ff).
    double visibleLagMs(CursorAnimationStyle s) =>
        tau(s) * (1.0 - s.feedforwardStrength) * 1000.0;

    test('Medium is the unchanged reference (380 / 1.0 / 0.5)', () {
      final m = CursorAnimationStyle.medium;
      expect(m.motionSpring.stiffness, 380);
      expect(m.motionSpring.damping, 1.0);
      expect(m.feedforwardStrength, 0.5);
    });

    test('only Smooth is underdamped (the floaty character)', () {
      expect(CursorAnimationStyle.smooth.motionSpring.damping, lessThan(1.0));
      expect(CursorAnimationStyle.medium.motionSpring.damping, 1.0);
      expect(CursorAnimationStyle.rapid.motionSpring.damping, 1.0);
    });

    test('feedforward strength is monotone: smooth < medium < rapid', () {
      expect(CursorAnimationStyle.smooth.feedforwardStrength,
          lessThan(CursorAnimationStyle.medium.feedforwardStrength));
      expect(CursorAnimationStyle.medium.feedforwardStrength,
          lessThan(CursorAnimationStyle.rapid.feedforwardStrength));
    });

    test('adjacent presets differ by ≥40 ms of visible lag '
        '(the perceptibility floor this redesign exists to enforce)', () {
      final smooth = visibleLagMs(CursorAnimationStyle.smooth);
      final medium = visibleLagMs(CursorAnimationStyle.medium);
      final rapid = visibleLagMs(CursorAnimationStyle.rapid);
      expect(smooth - medium, greaterThanOrEqualTo(40.0),
          reason: 'Smooth must visibly trail Medium');
      expect(medium - rapid, greaterThanOrEqualTo(40.0),
          reason: 'Medium must visibly trail Rapid');
      expect(rapid, lessThan(15.0),
          reason: 'Rapid should read as locked to the real path');
    });

    test('None stays the raw-grid snap', () {
      expect(CursorAnimationStyle.none.motionSpring.isSnap, isTrue);
      expect(CursorAnimationStyle.none.feedforwardStrength, 0.0);
    });

    test('config exposes the preset feedforward strength', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.rapid);
      expect(cfg.feedforwardStrength,
          CursorAnimationStyle.rapid.feedforwardStrength);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/animation_style_test.dart`
Expected: FAIL — `feedforwardStrength` getter does not exist (compile error).

- [ ] **Step 3: Implement**

In `packages/slipreel_engine/lib/rendering/animation_style.dart`:

3a. Replace the stale enum doc comment (lines 73-75, which claims a mapping to `ZoomFocalController.update`'s smoothing factor — that parameter no longer exists) with:

```dart
/// How the rendered cursor chases the recorded path. Each preset is a
/// spring chase with its own character: stiffness (how hard it pulls),
/// damping ratio (Smooth is slightly underdamped for a floaty, organic
/// feel), and velocity-feedforward strength (how much of the spring's
/// phase lag is cancelled while the cursor is moving — see
/// [CursorMotionController]). The camera focal chases the rendered
/// sprite, so the preset shapes the camera feel too.
```

3b. **Delete** the `smoothing` getter (lines 91-98, the `/// Lerp factor passed to...` doc plus the `double get smoothing => ...` switch). Nothing references it.

3c. Replace the `motionSpring` getter's switch values (keep the existing doc comment but update its text):

```dart
  /// Spring parameters that drive the cursor's motion chase. Each
  /// preset has a distinct character, not just a different settle
  /// time: Smooth is soft AND slightly underdamped (floaty arcs, a
  /// whisper of overshoot at stops); Medium is the balanced critically-
  /// damped reference; Rapid is a stiff, near-locked track; None
  /// snaps to the raw recorded grid. Paired with [feedforwardStrength]
  /// so the soft presets keep more of their natural trail.
  MotionSpring get motionSpring => switch (this) {
        CursorAnimationStyle.smooth =>
          const MotionSpring(stiffness: 90, damping: 0.8),
        CursorAnimationStyle.medium =>
          const MotionSpring(stiffness: 380, damping: 1.0),
        CursorAnimationStyle.rapid =>
          const MotionSpring(stiffness: 1400, damping: 1.0),
        CursorAnimationStyle.none => MotionSpring.snap,
      };
```

3d. Add the new getter right after `motionSpring`:

```dart
  /// Fraction of the spring's analytical phase lag (τ = 2ζ/ωₙ) that the
  /// velocity feedforward cancels while the cursor is moving (see
  /// [CursorMotionController]). Per-preset so the presets stay
  /// CONTRASTED: full-strength feedforward makes every spring sit on
  /// the raw path during motion, erasing the differences between them.
  /// Smooth keeps most of its lag (floaty trail); Rapid cancels almost
  /// all of it (locked). None bypasses the spring entirely — 0.0 here
  /// is never read, defined for completeness.
  double get feedforwardStrength => switch (this) {
        CursorAnimationStyle.smooth => 0.25,
        CursorAnimationStyle.medium => 0.5,
        CursorAnimationStyle.rapid => 0.85,
        CursorAnimationStyle.none => 0.0,
      };
```

3e. Update the hover-demo getters so the picker tiles preview the new feels honestly:

```dart
  /// Curve used for the picker's hover demo. Smooth uses an overshooting
  /// curve so the demo shows the underdamped float; Rapid reads as an
  /// immediate lock.
  Curve get previewCurve => switch (this) {
        CursorAnimationStyle.smooth => Curves.easeOutBack,
        CursorAnimationStyle.medium => Curves.easeOutCubic,
        CursorAnimationStyle.rapid => Curves.easeOutQuint,
        CursorAnimationStyle.none => Curves.linear,
      };

  Duration get previewDuration => switch (this) {
        CursorAnimationStyle.smooth => const Duration(milliseconds: 1600),
        CursorAnimationStyle.medium => const Duration(milliseconds: 800),
        CursorAnimationStyle.rapid => const Duration(milliseconds: 250),
        CursorAnimationStyle.none => const Duration(milliseconds: 80),
      };
```

In `packages/slipreel_engine/lib/rendering/animation_config.dart`, add to `CursorAnimationConfig` (after the `motionSpring` getter, line 55):

```dart
  double get feedforwardStrength => _preset!.feedforwardStrength;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/animation_style_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Analyze + commit**

Run: `cd packages/slipreel_engine && fvm flutter analyze --no-fatal-infos lib/rendering/animation_style.dart lib/rendering/animation_config.dart test/rendering/animation_style_test.dart`
Expected: no warnings/errors (info-level is non-fatal).

```bash
git add packages/slipreel_engine/lib/rendering/animation_style.dart packages/slipreel_engine/lib/rendering/animation_config.dart packages/slipreel_engine/test/rendering/animation_style_test.dart
git commit -m "feat(animation): contrasted cursor presets + per-preset feedforward strength"
```

Note: the full engine suite is expected to have failures at this point — `cursor_motion_controller_test.dart` pins the OLD Smooth constants. Task 2 fixes them; do not "fix" them here.

---

### Task 2: Controller reads strength from the config + behavior tests

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart` (strength getter at line ~114, use-site at line ~329, doc comments at lines ~22-34 and ~101-114)
- Modify: `packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart` (rewrite the steady-state-lag test at lines ~210-258; add two character tests)

**Interfaces:**
- Consumes: `CursorAnimationConfig.feedforwardStrength` (Task 1).
- Produces: no API change — `update(...)` signature untouched. Behavior: `leadSec` now uses the config's per-preset strength.

- [ ] **Step 1: Update the two character tests + rewrite the pinned lag test (RED first)**

In `packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart`, replace the whole `constant-velocity motion: partial feedforward halves the spring's steady-state lag` test (lines ~210-258) with the following (it re-pins to **Medium**, whose spring and strength are unchanged, and fixes the stale `k=180` comment math):

```dart
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

      final rec = _record(List.generate(90, (i) {
        final tMicros = i * dtPerFrameMicros;
        return (
          micros: tMicros,
          x: (tMicros / 1e6) * velocityPxPerSec,
          y: 0.0,
          clicked: false,
        );
      }));
      // Drive ~750 ms — well past 3τ ≈ 308 ms, so the spring is in
      // steady state.
      final timeline = List.generate(45, (i) => i * dtPerFrameMicros);

      final ctrl = CursorMotionController();
      final last = _drive(
        ctrl,
        rec: rec,
        config:
            const CursorAnimationConfig.preset(CursorAnimationStyle.medium),
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
```

If the file does not already import `dart:math`, add `import 'dart:math' as math;` at the top.

Then ADD these two new tests after it (same group):

```dart
    test('presets are contrasted: Smooth trails ≥3× further than Rapid '
        'at constant velocity', () {
      const dtPerFrameMicros = 16667;
      const velocityPxPerSec = 1000.0;
      final rec = _record(List.generate(90, (i) {
        final tMicros = i * dtPerFrameMicros;
        return (
          micros: tMicros,
          x: (tMicros / 1e6) * velocityPxPerSec,
          y: 0.0,
          clicked: false,
        );
      }));
      final timeline = List.generate(45, (i) => i * dtPerFrameMicros);

      double lagFor(CursorAnimationStyle style) {
        final ctrl = CursorMotionController();
        final last = _drive(ctrl,
            rec: rec,
            config: CursorAnimationConfig.preset(style),
            microsTimeline: timeline);
        final expectedPos = (timeline.last / 1e6) * velocityPxPerSec;
        return expectedPos - last!.screenPos.dx;
      }

      final smoothLag = lagFor(CursorAnimationStyle.smooth);
      final rapidLag = lagFor(CursorAnimationStyle.rapid);
      expect(smoothLag, greaterThan(rapidLag * 3),
          reason: 'The whole point of the redesign: Smooth (soft spring, '
              'weak feedforward) must visibly trail; Rapid (stiff, strong '
              'feedforward) must track near-locked. '
              'smooth=${smoothLag.toStringAsFixed(1)}px '
              'rapid=${rapidLag.toStringAsFixed(1)}px');
      expect(rapidLag.abs(), lessThan(20.0),
          reason: 'Rapid should read as locked (�precision of one cursor '
              'width at 1000 px/s)');
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
      final rec = _record(List.generate(120, (i) {
        final tMicros = i * dtPerFrameMicros;
        final tSec = tMicros / 1e6;
        final x = tSec < 0.5 ? tSec * 1000.0 : 500.0;
        return (micros: tMicros, x: x, y: 0.0, clicked: false);
      }));
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
      expect(smoothOver, greaterThan(mediumOver),
          reason: 'Underdamped Smooth должен drift past the stop point '
              'further than critically-damped Medium. '
              'smooth=${smoothOver.toStringAsFixed(2)}px '
              'medium=${mediumOver.toStringAsFixed(2)}px');
      expect(smoothOver, lessThan(25.0),
          reason: 'The float must stay tasteful — a drift, not a boomerang.');
    });
```

(Note: fix the stray non-English word in the reason string — write "must drift past the stop point". It is included here so the implementer knows the intended sentence.)

- [ ] **Step 2: Run to verify current state fails correctly**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/cursor_motion_controller_test.dart`
Expected: the two NEW tests FAIL (controller still reads the global 0.5 strength for every preset, so Smooth/Rapid lags won't separate ≥3×). The rewritten Medium lag test may already pass (Medium == old math). Existing Smooth-pinned tests that were failing after Task 1 should now be assessed: only the rewritten one was pinned to Smooth's numbers.

- [ ] **Step 3: Implement the controller change**

In `packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart`:

3a. Delete the `_feedforwardStrength` getter (lines ~101-114, including its doc comment) and replace with nothing — the strength now comes from the config at the use site.

3b. At the lead computation (line ~329), change:

```dart
    final leadSec = tauSec * speedFactor * _feedforwardStrength * fadeScale;
```

to:

```dart
    final leadSec =
        tauSec * speedFactor * config.feedforwardStrength * fadeScale;
```

3c. Update the class doc comment (lines ~22-34): replace the sentence claiming "the strength at 0.5" / "Matches the half-shift the user settled on for the FIR before springs." with:

```dart
/// `raw + velocity × τ × strength`, where the strength is PER-PRESET
/// ([CursorAnimationConfig.feedforwardStrength]): Smooth keeps most of
/// its natural trail (0.25), Medium halves its lag (0.5), Rapid cancels
/// almost all of it (0.85). Full cancellation would make every preset
/// sit on the raw path during motion — erasing exactly the contrast the
/// presets exist to provide.
```

3d. Update the in-method comment above the lead computation (lines ~300-312) the same way: replace "multiplied by [_feedforwardStrength]" with "multiplied by the preset's [CursorAnimationConfig.feedforwardStrength]" and delete the "Halves the steady-state lag" sentence (no longer universally true).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/cursor_motion_controller_test.dart`
Expected: PASS, including both new character tests and the rewritten Medium lag test.

- [ ] **Step 5: Run neighboring suites (spring feel is consumed downstream)**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/ test/state/`
Expected: PASS. `scene_pass_builder_speed_test.dart` uses the Smooth preset but asserts speed-INVARIANCE (1× vs sped-up comparisons with the same preset), which is constant-independent — if it fails, read the failure: a tolerance may need widening for the softer spring, but the invariance property itself must hold. Do not weaken any speed-invariance assertion to pass; report it instead.

- [ ] **Step 6: Analyze + commit**

Run: `cd packages/slipreel_engine && fvm flutter analyze --no-fatal-infos lib/rendering/cursor_motion_controller.dart test/rendering/cursor_motion_controller_test.dart`
Expected: no warnings/errors.

```bash
git add packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart
git commit -m "feat(animation): cursor feedforward strength comes from the preset"
```

---

### Task 3: Screen preset contrast (Focused vs Smooth)

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/animation_style.dart:29-70` (the `ScreenAnimationStyleData` extension)
- Test: `packages/slipreel_engine/test/rendering/animation_style_test.dart` (extend — file created in Task 1)

**Interfaces:**
- Consumes/produces: getter names unchanged (`badgeDuration`, `badgeCurve`, `rampCurve`, `rampDurationScale`, `previewCurve`, `previewDuration`) — only values change. Consumers (`playback_canvas`, `scene_blur_overlay`, `frame_compositor`, `zoom_focal_controller`) need no edits.

- [ ] **Step 1: Write the failing tests**

Append to `packages/slipreel_engine/test/rendering/animation_style_test.dart` (inside `main()`, as a new group):

```dart
  group('ScreenAnimationStyle presets', () {
    test('ramp duration spread is ≥3× (Focused snaps, Smooth glides)', () {
      final f = ScreenAnimationStyle.focused.rampDurationScale;
      final s = ScreenAnimationStyle.smooth.rampDurationScale;
      expect(s / f, greaterThanOrEqualTo(3.0));
      expect(f, lessThan(1.0), reason: 'Focused quickens the ramp');
      expect(s, greaterThan(1.0), reason: 'Smooth stretches the ramp');
    });

    test('curve shapes are opposite: Focused starts fast, Smooth winds up',
        () {
      // A quarter of the way through the ramp, Focused (fast-out) must be
      // far ahead of Smooth (pronounced ease-in start). This is the
      // perceptible signature of the two feels.
      final focusedAtQuarter =
          ScreenAnimationStyle.focused.rampCurve.transform(0.25);
      final smoothAtQuarter =
          ScreenAnimationStyle.smooth.rampCurve.transform(0.25);
      expect(focusedAtQuarter, greaterThan(smoothAtQuarter + 0.15));
    });

    test('badge tween: Focused snaps (<200 ms), Smooth lingers (>500 ms)',
        () {
      expect(ScreenAnimationStyle.focused.badgeDuration.inMilliseconds,
          lessThan(200));
      expect(ScreenAnimationStyle.smooth.badgeDuration.inMilliseconds,
          greaterThan(500));
    });

    test('picker demo mirrors the real ramp curve (honest preview)', () {
      for (final s in ScreenAnimationStyle.values) {
        expect(s.previewCurve, s.rampCurve);
      }
      expect(
          ScreenAnimationStyle.smooth.previewDuration >
              ScreenAnimationStyle.focused.previewDuration,
          isTrue);
    });
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/animation_style_test.dart`
Expected: the new group FAILS (spread is 1.4/0.55 ≈ 2.5×; previewCurve is `easeOutCubic`, not the ramp curve).

- [ ] **Step 3: Implement**

In `packages/slipreel_engine/lib/rendering/animation_style.dart`, update the `ScreenAnimationStyleData` values (getter shells unchanged):

```dart
  Duration get badgeDuration => switch (this) {
        ScreenAnimationStyle.focused => const Duration(milliseconds: 140),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 600),
      };
```

```dart
  /// Curve used for the zoom region's enter/exit ramps. The two presets
  /// have OPPOSITE shapes so they read differently at a glance:
  /// Focused accelerates instantly and settles hard (snaps and locks);
  /// Smooth is a pronounced ease-in-out — the camera visibly gathers
  /// momentum, glides, and soft-lands (the film push).
  Curve get rampCurve => switch (this) {
        ScreenAnimationStyle.focused => const Cubic(0.2, 0.0, 0.0, 1.0),
        ScreenAnimationStyle.smooth => const Cubic(0.65, 0.0, 0.35, 1.0),
      };
```

```dart
  double get rampDurationScale => switch (this) {
        // ≥3× spread: ≈250 ms vs ≈850 ms on a default 500 ms ramp.
        ScreenAnimationStyle.focused => 0.5,
        ScreenAnimationStyle.smooth => 1.7,
      };
```

```dart
  /// The picker's hover demo runs the REAL ramp curve so the tile
  /// honestly previews the feel it selects.
  Curve get previewCurve => rampCurve;

  Duration get previewDuration => switch (this) {
        ScreenAnimationStyle.focused => const Duration(milliseconds: 600),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 1500),
      };
```

Leave `label`, `description`, and `badgeCurve` untouched.

- [ ] **Step 4: Run tests**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/animation_style_test.dart`
Expected: PASS (both groups).

- [ ] **Step 5: Grep for tests pinned to the old screen constants, then run the engine suite**

Run: `cd packages/slipreel_engine && grep -rn "0\.55\|1\.4\|rampDurationScale" test/ --include="*.dart" | grep -v animation_style_test`
Then: `fvm flutter test`
Expected: full engine suite PASS. If a test pins the old 0.55/1.4 scales or the old cubics, update its expected values to the new constants (the test's intent — that the style threads through — is unchanged); report which ones were touched.

- [ ] **Step 6: Analyze + commit**

Run: `cd packages/slipreel_engine && fvm flutter analyze --no-fatal-infos lib/rendering/animation_style.dart test/rendering/animation_style_test.dart`
Expected: no warnings/errors.

```bash
git add packages/slipreel_engine/lib/rendering/animation_style.dart packages/slipreel_engine/test/rendering/animation_style_test.dart
git commit -m "feat(animation): contrasted screen presets (opposite curves, 3.4x spread)"
```

If Step 5 touched other test files, include them in the same commit.

---

### Task 4: Full verification + live feel session + finish

**Files:** none (verification only).

- [ ] **Step 1: Full engine suite**

Run: `cd packages/slipreel_engine && fvm flutter test`
Expected: PASS.

- [ ] **Step 2: Full recorder suite**

Run: `cd packages/screen_recorder && fvm flutter test`
Expected: PASS (~753 + ~14 pre-existing skips). The animation tab consumes only getters whose names are unchanged.

- [ ] **Step 3: Analyze both packages (CI parity)**

Run: `cd packages/slipreel_engine && fvm flutter analyze --no-fatal-infos && cd ../screen_recorder && fvm flutter analyze --no-fatal-infos`
Expected: no NEW issues (3 pre-existing `unnecessary_import` infos in `zoom_transformer_test.dart` are known and non-fatal).

- [ ] **Step 4: Live feel session (human-owned)**

Build `fvm flutter build macos --release` in `packages/screen_recorder`, kill any running instance (`osascript -e 'quit app "Slipreel"'`), `open -n` the fresh build. User A/Bs: all four cursor presets on a real recording (watch the sprite AND the camera feel), both screen presets on the same zoom ramp, the picker demo tiles. Constants are taste calls — expect a tuning iteration on `stiffness`/`feedforwardStrength`/`rampDurationScale` values before merge; re-run `animation_style_test` + `cursor_motion_controller_test` after any retune (the gap/character assertions are the guardrails).

- [ ] **Step 5: Finish the branch**

Invoke `superpowers:finishing-a-development-branch`: push, PR to `main` (title `feat(animation): contrasted cursor + screen animation presets`), merge on green CI. Update project memory (new memory file for this sub-project + MEMORY.md index line).

---

## Self-Review

**Spec coverage:** cursor preset table (values, per-preset ff, Medium/None unchanged) → Tasks 1-2 ✓; controller reads config strength, MotionTuning field retained but unread in production → Task 2 ✓; screen preset table → Task 3 ✓; dead `smoothing` getter + stale doc removal → Task 1 ✓; honest picker demos (cursor + screen) → Tasks 1/3 ✓; visible-lag-gap ≥40 ms and overshoot-bounded tests → Tasks 1-2 ✓; suites + live feel session → Task 4 ✓.

**Placeholders:** none — every code step shows the code; the one flagged typo in a reason string carries its correction inline.

**Type consistency:** `feedforwardStrength` (style extension + config delegate) used identically in Tasks 1-2; `MotionSpring(stiffness:, damping:)` matches `spring_config.dart`; screen getter names unchanged so no consumer edits.
