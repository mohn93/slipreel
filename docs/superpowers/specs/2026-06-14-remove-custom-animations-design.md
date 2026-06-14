# Remove Custom Animation Variants — Design

**Date:** 2026-06-14
**Status:** Approved (scope confirmed by user), pending implementation
**Area:** `slipreel_engine` animation config + `screen_recorder` inspector UI

## Problem / Decision

The two animation config classes each expose a "custom" path alongside their presets:
- `ScreenAnimationConfig` — `.preset(...)` **and** `.custom({CubicBezierCurve curve, Duration? badgeDuration})`.
- `CursorAnimationConfig` — `.preset(...)`, `.custom({curve, window})` (legacy FIR), **and** `.customSpring({MotionSpring spring})`.

The custom paths are surfaced by a bezier **Curve editor** (Animation tab, screen + cursor) and the **Springs sliders**
(Cursor tab → `customSpring`). The user has decided these customization features are not worth their complexity.

**Decision:** Remove the custom variants entirely; keep presets only.
- `ScreenAnimationStyle`: Focused / Smooth — kept.
- `CursorAnimationStyle`: Smooth / Medium / Rapid / None — kept.
- Remove: `.custom`/`.customSpring` constructors, their fields/getters (`isCustom`, `isCustomSpring`, `customCurve`,
  `_customCurve`, `_customWindow`, `_customFlutterCurve`, `_customSpring`, `_customBadgeDuration`), the custom JSON
  read/write, the Animation-tab Curve editor blocks + `_CustomTile`, and the Cursor-tab Springs section.

## Out of scope (must NOT change)

- `MotionSpring` (`spring_config.dart`) — still used by every preset's `motionSpring` getter and by MotionTuning.
- The global **MotionTuning** "springs playground" (Settings) — a separate system; untouched.
- The shared `CurveEditor` widget (`curve_editor.dart`) — still used by `zoom_context_inspector.dart` for per-region
  ramp-curve overrides. We only remove its *usages* in `animation_tab.dart`, not the widget.
- Per-`ZoomRegion` `rampCurveOverride` — a different feature; untouched.
- The preset enums and their data (`animation_style.dart`) — untouched. `CursorAnimationConfig.motionSpring`,
  `.window`, `.firCurve` getters are kept but simplified to read the preset directly.

## Migration (backward compatibility)

Existing saved projects may contain a custom config in JSON. Loading must NOT throw or lose the project.

- `ScreenAnimationConfig.fromJson`: if the JSON has no recognized `preset` (e.g. it carries `curve` /
  `badgeDurationMicros` from an old custom config), return `ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth)`.
- `CursorAnimationConfig.fromJson`: if the JSON carries `spring` or `curve`/`windowMicros` (old custom/customSpring),
  return `CursorAnimationConfig.preset(CursorAnimationStyle.smooth)`.
- An unrecognized **preset name** still throws `FormatException` (genuinely corrupt data, not a known legacy shape) —
  unchanged from today, and `EditorProjectState.fromJson` already degrades gracefully around it.
- `toJson` now only ever emits `{'preset': name}`, so re-saving a migrated project drops the legacy custom keys.

Smooth is the chosen fallback for both because it was the implicit default these custom configs branched from.

## UI changes

- **Animation tab** (`animation_tab.dart`): remove the two `_CustomTile`s, the two conditional `CurveEditor` blocks,
  the `_defaultScreenCustomCurve` / `_defaultCursorCustomCurve` constants, the `_CustomTile` class, and the now-unused
  `CurveEditor` import. Screen and Cursor sections become preset-pickers only (the existing preset tiles stay).
- **Cursor tab** (`cursor_tab.dart`): remove the entire **Springs** section (header + `_motionSpringSliders` +
  `_setMotionSpring`) and the now-unused `MotionSpring` import. Cursor motion feel is now governed solely by the
  chosen `CursorAnimationStyle` preset (whose `motionSpring` still drives the controller).

## Risk

- The simplified `badgeCurve`/`rampCurve`/`badgeDuration`/`window`/`firCurve`/`motionSpring` getters now do
  `_preset!.…`. Since the only remaining constructor is `.preset` (which always sets `_preset` non-null), the `!` is
  safe — but every getter must be checked so none still references a deleted `_custom*` field.
- Any read site of `.isCustom`/`.customCurve`/`.customSpring`/`.isCustomSpring` outside the two tabs must be removed
  (audit: motion_blur_playground_screen.dart and others). A missed reference is a compile error, which the build
  surfaces — but the plan enumerates them so none is silently `?? fallback`-ed.
- `operator==`/`hashCode` on `CursorAnimationConfig` must drop the removed fields, or value-equality breaks the
  EditorProjectState `==` (which has state-wide no-op-setX behavior).

## Verification

- `flutter analyze` clean in both packages (catches any stray custom reference).
- Unit: preset round-trips unchanged; legacy custom JSON (screen curve+badge, cursor curve+window, cursor spring) all
  load as the Smooth preset; `toJson` emits only `{'preset': …}`.
- Full `slipreel_engine` + `screen_recorder` suites green (deleting/rewriting the custom-specific tests).
- Runtime probe: Animation tab shows preset tiles only (no Custom tile / no curve editor); Cursor tab has no Springs
  section; switching presets still changes feel; an old project with a custom config opens as Smooth without error.
