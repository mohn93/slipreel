# Custom Animation Curves — Design

**Status:** Approved
**Date:** 2026-05-03
**Owner:** ScreenFlow Studio editor

## Goal

Let users author their own animation curves through a graph editor (After Effects style) and reuse them across recordings, while keeping the existing English-named presets (Focused / Smooth, and Smooth / Medium / Rapid / None) untouched as quick-pick options.

Custom curves apply to all three animated contexts:

1. Screen-level zoom ramp + badge animation.
2. Cursor follow smoothing.
3. Per-zoom-region ramp override.

## Architecture

A new `AnimationCurve` value type replaces "any place that today reads a Flutter `Curve` from an enum extension". The existing `ScreenAnimationStyle` / `CursorAnimationStyle` enums stay — they become *one source of presets* in the new picker rather than the only choice.

```
+--------------------+         +-----------------------+
| Inspector picker   | ----->  | AnimationCurve value  |
| [presets][Custom]  |         | (preset | bezier 4-tup) |
+--------------------+         +-----------------------+
                                          |
                                          v
            +-----------------+   +-----------------+   +-----------------+
            | ScreenAnim      |   | CursorAnim      |   | ZoomRegion      |
            | Config          |   | Config          |   | (override)      |
            +-----------------+   +-----------------+   +-----------------+
                     |                    |                     |
                     v                    v                     v
            +-----------------+   +--------------------+   +-----------------+
            | ZoomTransformer |   | CursorMotion       |   | (per-region    |
            | (ramp/badge)    |   | Controller (FIR)   |   |  ramp curve)   |
            +-----------------+   +--------------------+   +-----------------+
```

Library of named curves is a separate, app-global service used only by the editor.

## Data Model

```dart
sealed class AnimationCurve {
  const AnimationCurve();
  Curve toFlutterCurve();
  Map<String, dynamic> toJson();
}

class PresetCurve extends AnimationCurve {
  final String presetId; // 'screen.focused', 'cursor.smooth', 'lib:linear'
}

class CubicBezierCurve extends AnimationCurve {
  final double x1, y1, x2, y2;
  // No name field. Library identity lives in NamedCurve.
}
```

Per-context configs:

```dart
class ScreenAnimationConfig {
  final ScreenAnimationStyle? preset;       // null when custom
  final CubicBezierCurve?     customCurve;  // applies to ramp + badge
  final Duration?             customBadgeDuration; // null = inherit from default Smooth preset
}

class CursorAnimationConfig {
  final CursorAnimationStyle? preset;
  final CubicBezierCurve?     customCurve;
  final Duration?             customWindow;     // FIR catch-up window
}
```

`ZoomRegion` gains:

```dart
final AnimationCurve? rampCurveOverride;
```

`null` → inherit ramp curve from the global `ScreenAnimationConfig`. (Per-region ramp **durations** already exist as `enterDuration`/`exitDuration` on `ZoomRegion`, so no new duration override field is needed.) JSON serialization is backward-compatible: missing fields read as `null`.

In-recording serialization stores raw 4-tuples for custom curves, *not* library ids. Recordings travel without depending on the recipient's library.

## Picker UI

Each existing preset row gains a **Custom** tile at the end:

```
[Focused] [Smooth] [Custom]
```

When *Custom* is selected, the inspector expands an inline editor below the row. Inspector is ~280px wide; editor lays out vertically:

```
┌─────────────────────────────┐
│  240×240 bezier graph       │
│   (start (0,0), end (1,1),  │
│    two draggable handles,   │
│    tangent guide lines)     │
├─────────────────────────────┤
│  • • • • • • • ⚪  →  loop  │  ← live demo dot driven by current curve
├─────────────────────────────┤
│  x1 [_]  y1 [_]             │
│  x2 [_]  y2 [_]             │  ← 4 numeric inputs (clamped on commit)
├─────────────────────────────┤
│  Duration  ────●────  320ms │  ← screen Custom: badge tween duration
│                              │  ← cursor Custom: "Catch-up window" 0–1500ms
│                              │  ← per-region override: hidden (durations on region)
├─────────────────────────────┤
│  Library                    │
│  [linear][ease][ease-in]    │  ← built-in chips
│  [ease-out][ease-in-out]    │
│  [my snap-back][my push]    │  ← saved chips
├─────────────────────────────┤
│  [Save to library…]         │
└─────────────────────────────┘
```

Behavior:

- **Live drag.** Moving a handle (or editing a numeric field) immediately applies the curve to the recording. No Apply button. Switching back to a preset tile reverts.
- **Constraints.** `x1`, `x2` clamp to `[0, 1]` (monotonic in time). `y1`, `y2` are free in roughly `[-0.5, 1.5]` so users can author overshoot.
- **Numeric input commit.** Edits commit on Enter, Tab, or focus loss; clamping is applied at commit time, not on every keystroke.
- **Evaluation.** Use Flutter's built-in `Cubic(x1, y1, x2, y2)` — Newton-Raphson is built in.
- **Library chips.** First row: built-in standards (linear, ease, ease-in, ease-out, ease-in-out). Second row: user's saved curves. Click overwrites the current handles. Right-click → delete confirm (saved chips only).
- **Save to library.** Inline name field + Save button. Empty name = no save. Same-name save → overwrite confirm dialog. Persists to disk.
- **Detachment.** Clicking a library chip highlights it; dragging a handle afterward "detaches" the highlight. Curve becomes scratch.

## Cursor Model Change

Today: per-frame IIR lerp `rendered = lerp(rendered_prev, target, α)`. There are no endpoints for a curve to live between, so curves don't fit naturally.

New: stateless **causal FIR** convolution over the recorded path.

```dart
// per (curve, window):
N = (window * fps).round()
weights[i] = curve(1 - i/N) - curve(1 - (i+1)/N)   // discrete derivative
weights /= sum(weights)                            // normalize

// per frame:
renderedPos = Σ weights[i] * cursorAt(position - i * framePeriod)
```

Cost: ~30 multiply-adds/frame. Sampling reuses the existing `cursorAt(recording, time)` interpolator.

Why this is cleaner:

- The current scrub-snap heuristic in `CursorMotionController` disappears. Each frame computes from scratch, so jumping the playhead has no stale state to reset.
- Idempotency cache keyed by `(position, configHash)` stays — same parent-`setState`-double-builder issue as `ZoomFocalController`.
- Kernel cache: only recompute when `(window, curve)` changes.
- `window == 0` bypasses FIR and samples raw — matches "None" preset and bottom of the Custom slider.
- Edge of recording: taps with `position - i*framePeriod < 0` clamp to time 0. Slight start-of-clip bias, acceptable.

**Preset re-tuning** (one-time table; iterated visually until each preset feels indistinguishable from today):

| Preset | Window | Curve | Current IIR equivalent |
|---|---|---|---|
| Smooth | 450ms | easeOutCubic | α=0.08, ~450ms 90% rise |
| Medium | 180ms | easeOutCubic | α=0.18, ~180ms 90% rise |
| Rapid  | 65ms  | easeOutCubic | α=0.40, ~65ms  90% rise |
| None   | 0ms   | linear (no-op) | α=1.0, snap |

## Per-Zoom-Region Override

Override applies to the region's enter/exit ramp curve only — never to the badge curve (which is a global UX behavior). Ramp durations stay on the region itself via the existing `enterDuration`/`exitDuration`. `ZoomTransformer.getTransform`'s existing `rampCurve` parameter is reused; `playback_screen.dart` chooses `region.rampCurveOverride?.toFlutterCurve() ?? globalConfig.curve` per region.

Inspector region detail panel grows a collapsible "Animation override" section:

```
▾ Animation override   [● off / ○ on]
   ┌─ when on ────────────────────┐
   │ [Focused][Smooth][Custom]    │
   │ [inline editor if Custom]    │
   └──────────────────────────────┘
```

Same inline editor component as the global picker, just bound to the region's override fields.

## Saved Library

```dart
abstract class CurveLibrary {
  Stream<List<NamedCurve>> watch();
  Future<NamedCurve> save({required String name, required CubicBezierCurve curve});
  Future<void> rename(String id, String newName);
  Future<void> delete(String id);
}

class NamedCurve {
  final String id;        // uuid v4
  final String name;
  final CubicBezierCurve curve;
}
```

Storage: `getApplicationSupportDirectory()/screenflow/curves.json`.

```json
{
  "version": 1,
  "curves": [
    { "id": "1f3a…", "name": "snap-back",
      "x1": 0.42, "y1": 0.0, "x2": 0.58, "y2": 1.4 }
  ]
}
```

- **Atomic writes.** Write `curves.json.tmp`, then `rename`. No corruption on mid-write crash.
- **Built-in standards** (linear, ease, ease-in, ease-out, ease-in-out) live in code; never appear in the JSON file. Always rendered first in the chip row.
- **Debounce.** 300ms on save/rename to avoid disk thrash on rapid edits.
- **Bad JSON.** Yields empty library + warning log; never crashes the editor.

## File Structure

New files:

- `lib/rendering/animation_curve.dart` — sealed `AnimationCurve`, `CubicBezierCurve`, `PresetCurve`, JSON roundtrip.
- `lib/rendering/animation_config.dart` — `ScreenAnimationConfig`, `CursorAnimationConfig` value types.
- `lib/services/curve_library.dart` — `CurveLibrary` interface + file-backed implementation.
- `lib/ui/widgets/inspector/curve_editor.dart` — inline graph editor widget (graph + handles + numeric inputs + duration slider + chip row + save UI).
- `lib/ui/widgets/inspector/curve_graph_painter.dart` — `CustomPainter` for graph + handles + tangent guides + demo dot.

Modified files:

- `lib/rendering/animation_style.dart` — keep enums, add a method on each that returns its `(Duration, Curve)` tuple for use as a built-in preset.
- `lib/ui/widgets/zoom/cursor_motion_controller.dart` — replace IIR lerp with FIR convolution; drop scrub-snap; cache kernel.
- `lib/effects/zoom_transformer.dart` — no signature change; `rampCurve` parameter already exists.
- `lib/models/zoom_region.dart` — add `rampCurveOverride`; backward-compatible JSON.
- `lib/ui/widgets/inspector/tabs/animation_tab.dart` — add Custom tile + inline editor wiring; lift `ScreenAnimationConfig` / `CursorAnimationConfig` props.
- `lib/ui/widgets/inspector/inspector_panel.dart` — region detail panel grows the override section.
- `lib/ui/screens/playback_screen.dart` — replace enum state with config state; pass region-or-global ramp curve+duration into `ZoomTransformer`; pass cursor config into `CursorMotionController`.

## Testing

1. **`CubicBezierCurve` unit** — JSON roundtrip; `toFlutterCurve` produces `Cubic` with matching params; equality is value-based.
2. **`CurveLibrary` unit** — save/list/rename/delete against a temp dir; atomic write leaves no `.tmp` on success; corrupt JSON yields empty library + log warning, no crash.
3. **`CursorMotionController` FIR unit** — step response of each preset hits its target rise time within tolerance (validates re-tuning table); idempotent at same position; `window=0` bypasses FIR; kernel cache reused when `(window, curve)` unchanged; near-start-of-clip taps clamp without throwing.
4. **`ZoomTransformer` unit** — region's `rampCurveOverride` is used when set; null override falls back to global config.
5. **Editor widget tests** — handle drag clamps `x1`, `x2` to `[0, 1]`; numeric input edits flow back to model; library-chip click loads values; "Save to library" persists; per-region override toggle shows/hides editor.

Manual / visual:

- Side-by-side recording before/after the FIR rewrite at each cursor preset to confirm perceptual match.
- Pick Custom in editor → drag a handle → recording animates with new curve in real time.

## Out of Scope (v1)

- Multi-keyframe spline editing (the AE-full / Blender model). Cubic bezier covers 95% of easing needs; revisit if real demand surfaces.
- Curve sharing / import / export between users. Local-only library.
- Per-recording badge curve overrides (badge stays global).
- Custom curves on motion blur (motion blur itself isn't rendered yet).
