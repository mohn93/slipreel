# Remove Custom Animation Variants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `.custom`/`.customSpring` variants of `ScreenAnimationConfig` and `CursorAnimationConfig` (and the UI that creates them), keeping presets only; migrate legacy custom JSON to the Smooth preset on load.

**Architecture:** Both config classes collapse to a single `.preset(...)` constructor; their getters read the preset directly; `fromJson` returns `Smooth` when it sees a legacy custom shape. The Animation-tab Curve editors + `_CustomTile` and the Cursor-tab Springs section are deleted. `MotionSpring`, `CurveEditor` (still used by zoom-region overrides), MotionTuning, and the preset enums are untouched.

**Tech Stack:** Dart, Flutter, melos. Run tests with `flutter test <path>` (NO `-p vm` flag — `flutter test` rejects it; VM is the default).

Spec: `docs/superpowers/specs/2026-06-14-remove-custom-animations-design.md`

---

## Task 1: Collapse `ScreenAnimationConfig` to preset-only + migration

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/animation_config.dart`
- Test: `packages/slipreel_engine/test/rendering/animation_config_test.dart`

- [ ] **Step 1: Write the failing migration test**

Add to `animation_config_test.dart` (inside `main()`):

```dart
  test('ScreenAnimationConfig: legacy custom JSON migrates to Smooth', () {
    // Old custom shape: curve + badgeDurationMicros, no 'preset' key.
    final cfg = ScreenAnimationConfig.fromJson({
      'curve': {'type': 'cubic', 'x1': 0.4, 'y1': 0.0, 'x2': 0.2, 'y2': 1.0},
      'badgeDurationMicros': 250000,
    });
    expect(cfg.preset, ScreenAnimationStyle.smooth);
    expect(cfg.toJson(), {'preset': 'smooth'});
  });

  test('ScreenAnimationConfig: preset round-trips', () {
    final cfg = ScreenAnimationConfig.fromJson({'preset': 'focused'});
    expect(cfg.preset, ScreenAnimationStyle.focused);
    expect(cfg.rampCurve, ScreenAnimationStyle.focused.rampCurve);
    expect(cfg.toJson(), {'preset': 'focused'});
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/animation_config_test.dart --name "Screen"`
Expected: FAIL — the legacy-JSON test currently builds a `.custom` config (preset would be null), or once the body is edited, won't compile.

- [ ] **Step 3: Implement — replace the whole `ScreenAnimationConfig` class**

In `animation_config.dart`, replace the entire `ScreenAnimationConfig` class (from `class ScreenAnimationConfig {` through its closing `}`) with:

```dart
class ScreenAnimationConfig {
  const ScreenAnimationConfig.preset(ScreenAnimationStyle preset)
      : _preset = preset;

  final ScreenAnimationStyle? _preset;

  ScreenAnimationStyle? get preset => _preset;

  Curve get badgeCurve => _preset!.badgeCurve;
  Curve get rampCurve => _preset!.rampCurve;
  Duration get badgeDuration => _preset!.badgeDuration;

  Map<String, dynamic> toJson() => {'preset': _preset!.name};

  factory ScreenAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      for (final s in ScreenAnimationStyle.values) {
        if (s.name == presetName) return ScreenAnimationConfig.preset(s);
      }
      throw FormatException(
          'Unknown ScreenAnimationStyle preset: $presetName');
    }
    // Legacy custom config (curve + badgeDurationMicros) — migrate to Smooth.
    return const ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd packages/slipreel_engine && flutter test test/rendering/animation_config_test.dart`
Expected: PASS for the Screen tests. (Cursor tests still reference `.custom`/`.customSpring` and may fail to compile — that's Task 2; if the file won't compile, temporarily run only after Task 2. If so, note it and proceed; the suite is fully green at Task 2 Step 4.)

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/animation_config.dart packages/slipreel_engine/test/rendering/animation_config_test.dart
git commit -m "refactor(anim): ScreenAnimationConfig preset-only + legacy-custom JSON migrates to Smooth"
```

---

## Task 2: Collapse `CursorAnimationConfig` to preset-only + migration

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/animation_config.dart`
- Test: `packages/slipreel_engine/test/rendering/animation_config_test.dart`

- [ ] **Step 1: Write the failing migration tests**

Add to `animation_config_test.dart`:

```dart
  test('CursorAnimationConfig: legacy custom-curve JSON migrates to Smooth', () {
    final cfg = CursorAnimationConfig.fromJson({
      'curve': {'type': 'cubic', 'x1': 0.4, 'y1': 0.0, 'x2': 0.2, 'y2': 1.0},
      'windowMicros': 450000,
    });
    expect(cfg.preset, CursorAnimationStyle.smooth);
    expect(cfg.toJson(), {'preset': 'smooth'});
  });

  test('CursorAnimationConfig: legacy custom-spring JSON migrates to Smooth', () {
    final cfg = CursorAnimationConfig.fromJson({
      'spring': {'stiffness': 250.0, 'damping': 1.0},
    });
    expect(cfg.preset, CursorAnimationStyle.smooth);
    expect(cfg.motionSpring, CursorAnimationStyle.smooth.motionSpring);
  });

  test('CursorAnimationConfig: preset value-equality holds', () {
    expect(
      const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
      const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
    );
    expect(
      const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
      isNot(const CursorAnimationConfig.preset(CursorAnimationStyle.medium)),
    );
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/animation_config_test.dart --name "CursorAnimationConfig"`
Expected: FAIL/compile-error (the new tests expect migration the current `.fromJson` doesn't do, and Task 1's edit may already break compilation of the cursor `.custom` references in the test file — clean those in Step 3's test edits).

- [ ] **Step 3: Implement — replace the whole `CursorAnimationConfig` class**

In `animation_config.dart`, replace the entire `CursorAnimationConfig` class with:

```dart
class CursorAnimationConfig {
  const CursorAnimationConfig.preset(CursorAnimationStyle preset)
      : _preset = preset;

  final CursorAnimationStyle? _preset;

  CursorAnimationStyle? get preset => _preset;

  Duration get window => _preset!.fir.window;
  Curve get firCurve => _preset!.fir.curve;
  MotionSpring get motionSpring => _preset!.motionSpring;

  Map<String, dynamic> toJson() => {'preset': _preset!.name};

  factory CursorAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      for (final s in CursorAnimationStyle.values) {
        if (s.name == presetName) return CursorAnimationConfig.preset(s);
      }
      throw FormatException(
          'Unknown CursorAnimationStyle preset: $presetName');
    }
    // Legacy custom / custom-spring config (spring, or curve+windowMicros) —
    // migrate to the Smooth preset.
    return const CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CursorAnimationConfig && other._preset == _preset;

  @override
  int get hashCode => _preset.hashCode;
}
```

Then remove any now-unused import at the top of `animation_config.dart` (the `animation_curve.dart` import was only used by the deleted custom JSON paths; `spring_config.dart` is still used by `MotionSpring`). Run `flutter analyze lib/rendering/animation_config.dart` and delete whatever it flags as unused.

- [ ] **Step 4: Run to verify pass (whole engine animation tests)**

Run: `cd packages/slipreel_engine && flutter test test/rendering/animation_config_test.dart`
Expected: PASS. Also run `flutter analyze lib/rendering/animation_config.dart` → No issues.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/animation_config.dart packages/slipreel_engine/test/rendering/animation_config_test.dart
git commit -m "refactor(anim): CursorAnimationConfig preset-only (drop custom + customSpring) + migration"
```

---

## Task 3: Remove custom UI from the Animation tab

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart`

- [ ] **Step 1: Delete the custom UI**

In `animation_tab.dart`, delete all of the following (identify by content; line numbers are approximate):
- The `_defaultScreenCustomCurve` const (~36–41) and `_defaultCursorCustomCurve` const (~43–50).
- The screen-section `_CustomTile(...)` instance (selected by `screenAnimationConfig.isCustom`, ~87–100).
- The screen-section conditional `if (project.screenAnimationConfig.isCustom) CurveEditor(...)` block (~103–124).
- The cursor-section `_CustomTile(...)` instance (selected by `cursorAnimationConfig.customCurve != null`, ~153–178).
- The cursor-section conditional `if (project.cursorAnimationConfig.customCurve != null) CurveEditor(...)` block (~181–202).
- The `_CustomTile` widget class definition (~405–461).
- The `import '.../curve_editor.dart';` line (now unused here — `CurveEditor` stays used by `zoom_context_inspector.dart`, just not imported here).

Leave the preset tile rows (the `Wrap` of preset `_AnimationStyleTile`/equivalent) intact for both Screen and Cursor sections. Do NOT change the preset selection logic.

- [ ] **Step 2: Verify analyze clean**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/inspector/tabs/animation_tab.dart`
Expected: No issues. (If it flags an unused import or a leftover `isCustom`/`customCurve` reference, remove it.)

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart
git commit -m "refactor(anim): remove Custom curve editor from the Animation tab (presets only)"
```

---

## Task 4: Remove the Springs section from the Cursor tab

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/cursor_tab.dart`

- [ ] **Step 1: Delete the Springs section**

In `cursor_tab.dart`, delete:
- The `_setMotionSpring(MotionSpring s)` method (~44–50) and its doc comment (it is the only producer of
  `CursorAnimationConfig.customSpring`, which no longer exists).
- The entire **Springs** section in `build` — the section whose header is `'Springs'` (~163–182), including its
  `..._motionSpringSliders(project.cursorAnimationConfig.motionSpring)` spread.
- The `_motionSpringSliders(MotionSpring s)` helper method (~350–378) and its doc comment.
- The now-unused `MotionSpring` / `spring_config.dart` import (verify it isn't used elsewhere in the file first).

Leave the rest of the Cursor tab (preset picker, other sections) intact.

- [ ] **Step 2: Verify analyze clean**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/inspector/tabs/cursor_tab.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/cursor_tab.dart
git commit -m "refactor(anim): remove the Springs (custom-spring) section from the Cursor tab"
```

---

## Task 5: Audit & remove all remaining custom read sites

**Files:**
- Modify: any file still referencing the removed members (audit-driven).

- [ ] **Step 1: Audit**

Run from repo root:
```bash
grep -rn "\.isCustom\b\|\.isCustomSpring\b\|\.customCurve\b\|\.customSpring(\|ScreenAnimationConfig\.custom(\|CursorAnimationConfig\.custom(" packages --include="*.dart" | grep -v "_test.dart"
```
Expected remaining hits live in non-test lib files (e.g. `motion_blur_playground_screen.dart`). For each, remove the
custom branch / replace with the preset behavior. `motion_blur_playground_screen.dart` is a dev playground — if a hit
there only drove a custom-curve preview, delete that branch; keep its preset path. Do NOT introduce new behavior.

- [ ] **Step 2: Analyze both packages**

Run: `cd packages/slipreel_engine && flutter analyze lib && cd ../screen_recorder && flutter analyze lib`
Expected: No errors. Pre-existing unrelated warnings are fine — note, don't fix.

- [ ] **Step 3: Commit (only if files changed)**

```bash
git add -A
git commit -m "refactor(anim): drop remaining custom-config read sites"
```

If the audit found nothing outside the tabs already handled, skip this commit and note "no further read sites."

---

## Task 6: Tests cleanup + full-suite verification

**Files:**
- Modify: `packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart`
- Modify: `packages/slipreel_engine/test/state/editor_project_store_test.dart` (path per repo; find by name)
- Plus any other test constructing `.custom(`/`.customSpring(`.

- [ ] **Step 1: Find every test that constructs a custom config**

Run:
```bash
grep -rn "\.custom(\|\.customSpring(\|isCustom\|customCurve" packages --include="*_test.dart"
```

- [ ] **Step 2: Delete/rewrite**

- `cursor_motion_controller_test.dart`: delete the `'custom-spring config evaluates...'` test and the
  `'legacy custom-curve config still loads...'` test (they construct removed constructors). The preset-based tests stay.
- `editor_project_store_test.dart`: in the fixture, delete the `screenAnimationConfig: ScreenAnimationConfig.custom(...)`
  override (the cursor one already uses a preset). Add a test loading a project whose JSON carries a legacy custom
  screen config (`{'curve': {...}, 'badgeDurationMicros': ...}`) and assert the loaded `screenAnimationConfig.preset`
  is `ScreenAnimationStyle.smooth` and the project loads without throwing.
- Any other custom-constructing test: convert to a preset or delete if it solely tested the custom path.

- [ ] **Step 3: Run both full suites**

Run:
```bash
cd packages/slipreel_engine && flutter test
cd ../screen_recorder && flutter test
```
Expected: All green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test(anim): drop custom-config tests; add legacy-custom-JSON migration coverage"
```

- [ ] **Step 5: Runtime verification (operator)**

App is already running on this branch. Hot-restart it (or it will be relaunched), then: open the inspector → Animation
tab shows preset tiles only (no Custom tile, no curve editor); Cursor tab has no Springs section; switching presets
still changes feel; opening an older project that had a custom animation config loads as Smooth with no error.
