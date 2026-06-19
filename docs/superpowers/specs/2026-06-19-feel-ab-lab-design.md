# Feel A/B Lab — Design (Issue #7)

**Status:** Design — pending user review
**Issue:** #7 "Review & tune screen and cursor animation curves" (follow-up to #6)
**Date:** 2026-06-19

## Problem

The animation "feel" — how the cursor spring and the screen zoom enter/exit
ramp read *together* — needs a tuning pass aimed at the Screen Studio / FocuSee
look (eased push-in, settled follow). This is inherently subjective: it can only
be judged by watching motion, not from static frames. The codebase already has
all the levers (`ScreenAnimationStyle.rampCurve`, `CursorAnimationStyle.motionSpring`,
`MotionTuning` feedforward), but they live in three separate inspector pickers, so
comparing one cohesive *feel* against another means clicking three controls each time.

## Goal

Build an **in-app A/B toggle** that flips bundled cursor+screen "feels" live during
preview on a single control, so the user can pick the Screen-Studio-like one. Then
**bake the winner** into the shipped default. The toggle itself is a dev tool, gated
out of release builds.

## Decisions (from brainstorming)

- **Outcome:** build the A/B toggle first, then tune together, then bake. (User pick.)
- **Reference feel:** Screen Studio / FocuSee. (User pick.)
- **Toggle UI:** a "Feel A/B" row at the top of the existing inspector **Animation tab**,
  **debug-gated** (`kDebugMode`) so it never ships. (User pick.)
- **Candidates:** **dev-only** during tuning — they do NOT appear as permanent preset
  tiles in the user picker. Once a winner is chosen, promote it to the default. (User pick.)

## Key architectural principle

**Reuse the existing config path; do not add a parallel override layer.** The A/B
controller applies a bundle by calling the *existing* setters
(`EditorProjectController.setScreenAnimationConfig` / `setCursorAnimationConfig`,
`MotionTuningController.usePreset`). Because preview and export both read the same
`ScreenAnimationConfig` / `CursorAnimationConfig` values through the shared
`ScenePassBuilder` / `DeterministicFocalTrack` (verified: `playback_canvas.dart`
passes them as widget values; the focal controller reads `screenRampCurve` and the
cursor controller reads `config.motionSpring`), routing the A/B through the same
setters keeps preview ↔ export in lockstep automatically — the issue's explicit
constraint — with zero new render-pipeline branching.

## Approach: hidden "experimental" enum presets

The candidate feels are expressed as **new enum values** on `ScreenAnimationStyle`
and `CursorAnimationStyle`, flagged `experimental` and **filtered out of the user
picker**. This avoids any surgery on the core `ScreenAnimationConfig` /
`CursorAnimationConfig` classes (no re-introduction of a custom-curve path, no
null-preset handling), reuses 100% of the existing render + JSON round-trip wiring,
and makes "bake the winner" a one-line change (promote its curves into the default
style, or flip its flag to user-selectable).

Rejected alternative — re-introducing a custom-curve path in the config classes:
more flexible (arbitrary beziers at runtime) but reintroduces removed complexity
and null-preset force-unwrap risk across every consumer. Not needed for a curated
2–3 candidate set.

## Components

### 1. Experimental presets — `slipreel_engine/lib/rendering/animation_style.dart`

Add Screen-Studio-aimed enum values:

- `ScreenAnimationStyle.studioSoft`, `ScreenAnimationStyle.studioSnappy`
  - `rampCurve`: an eased push-in (e.g. `Curves.easeInOutCubic` softened / a
    `Cubic` tuned toward a slow-out settle). Exact values are *starting points* —
    the whole point is to refine while A/B-ing.
  - `badgeCurve` / `badgeDuration` / `previewCurve` / `previewDuration`: sensible
    matches so the existing tile/demo code keeps working if ever shown.
- `CursorAnimationStyle.studioSoft`, `CursorAnimationStyle.studioSnappy`
  - `motionSpring`: critically-damped springs tuned for a Screen-Studio settle
    (softer stiffness for Soft, firmer for Snappy), plus matching `fir`/`smoothing`
    /`previewCurve`/`previewDuration` so all existing switch-expressions stay total.

Add `bool get experimental` to each extension:
- `ScreenAnimationStyleData.experimental` → true for studioSoft/studioSnappy, else false.
- `CursorAnimationStyleData.experimental` → true for studioSoft/studioSnappy, else false.

### 2. `FeelVariant` bundles — `slipreel_engine/lib/rendering/feel_variant.dart` (new)

```
@immutable
class FeelVariant {
  const FeelVariant({required this.label, required this.screen,
      required this.cursor, required this.tuning});
  final String label;
  final ScreenAnimationStyle screen;
  final CursorAnimationStyle cursor;
  final MotionTuningPreset tuning;

  static const List<FeelVariant> candidates = [
    FeelVariant(label: 'Default',       screen: smooth,      cursor: smooth,      tuning: defaults),
    FeelVariant(label: 'Studio Soft',   screen: studioSoft,  cursor: studioSoft,  tuning: cinematic),
    FeelVariant(label: 'Studio Snappy', screen: studioSnappy,cursor: studioSnappy,tuning: snappy),
  ];
}
```

(Exact pairings are starting points; refined during tuning.)

### 3. `FeelLabController` — `screen_recorder/lib/state/feel_lab_controller.dart` (new)

A `StateNotifier<int>` (active candidate index; `0` = Default).

- On first non-zero apply, **snapshots** the project's entry `screenAnimationConfig`,
  `cursorAnimationConfig`, and the active `MotionTuning` so the lab is non-destructive.
- `apply(int i, WidgetRef/Reader)`: calls
  `editorProjectController.setScreenAnimationConfig(ScreenAnimationConfig.preset(v.screen))`,
  `...setCursorAnimationConfig(CursorAnimationConfig.preset(v.cursor))`,
  `motionTuningController.usePreset(v.tuning)`.
- `cycle()` / `cyclePrev()`: advance/retreat the index with wraparound, then `apply`.
- `restore()`: re-apply the entry snapshot (used if the user backs out without committing).
- `commit()`: clears the snapshot — the current config becomes the new baseline
  (this is what "I like this one" does before the bake step).

Provider `feelLabControllerProvider` (plain `StateNotifierProvider`, not overridden;
dev-only). The controller needs a `Ref` to reach the other controllers — pass it in.

### 4. Animation-tab row — `screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart`

- Filter the two existing picker loops to non-experimental values:
  `for (final s in ScreenAnimationStyle.values.where((s) => !s.experimental))` and
  the cursor equivalent. (Experimental presets never show as tiles.)
- Prepend a `kDebugMode`-gated **"Feel A/B (dev)"** row: shows the active variant
  label with `‹` / `›` buttons (and optionally numbered chips) that call
  `feelLabController.cyclePrev()` / `cycle()` / `apply(i)`. A small "Reset" affordance
  calls `restore()`. The row is wrapped in `if (kDebugMode) ...[ ... ]` so release
  builds compile it out entirely.

### 5. `ext.slipreel.setFeel` hook — `screen_recorder/lib/main.dart`

Register `ext.slipreel.setFeel` taking `{index}` (or `{label}`) and applying the
variant via the same controller, so the feel can be driven/verified programmatically
during runtime verification (the editor canvas isn't tappable via the flutter-qa
probe — the AppAlerts overlay occludes the semantics tree). Mirrors the existing
`ext.slipreel.*` registrations. Debug-gated alongside the others.

### 6. Bake step (separate, after the user picks)

Once the user chooses a winner in the lab, a follow-up change promotes that feel to
the default: update the default `ScreenAnimationStyle` / `CursorAnimationStyle` (or
copy the winning curves into `smooth`/`focused`) and the default `MotionTuning`, and
remove/keep the experimental values as appropriate. Not part of the toggle build.

## Testing

- **Enum filter:** `ScreenAnimationStyle.values.where((s) => !s.experimental)` excludes
  studio* ; the user-facing list length is unchanged from today. Same for cursor.
- **Switch totality:** all existing `switch` expressions over the enums stay exhaustive
  with the new values (compile-time; a smoke test reads `.rampCurve`/`.motionSpring`/
  `.label` for every value incl. experimental).
- **FeelLabController:** `apply(i)` calls the three setters with the i-th variant's
  configs (fake/stub controllers capture the calls); `cycle()` wraps; `restore()`
  re-applies the snapshot; `commit()` clears it.
- **JSON round-trip:** a project saved with an experimental preset name round-trips
  back to the same value (the `fromJson` name-match loop already covers all values).
- **Animation tab:** the picker renders only non-experimental tiles; the Feel A/B row
  is present under `kDebugMode` (widget test pumps with the dev gate).

## Out of scope

- The actual final curve values (that's the *tuning*, done live with the user after
  the toggle lands).
- Persisting the chosen feel as a user setting (dev tool; the bake step sets the default).
- Any change to export behavior beyond what flows automatically from the shared config.

## Files

- Modify: `slipreel_engine/lib/rendering/animation_style.dart` (experimental values + flag)
- Create: `slipreel_engine/lib/rendering/feel_variant.dart`
- Create: `screen_recorder/lib/state/feel_lab_controller.dart`
- Modify: `screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart` (filter + dev row)
- Modify: `screen_recorder/lib/main.dart` (`ext.slipreel.setFeel`)
- Tests: `slipreel_engine/test/rendering/animation_style_experimental_test.dart`,
  `slipreel_engine/test/rendering/feel_variant_test.dart`,
  `screen_recorder/test/state/feel_lab_controller_test.dart`,
  `screen_recorder/test/ui/widgets/inspector/animation_tab_feel_row_test.dart`
