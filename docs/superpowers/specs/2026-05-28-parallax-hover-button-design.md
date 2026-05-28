# SpringHoverButton: inner-content parallax on hover

**Date:** 2026-05-28
**Status:** Approved (design)
**Scope:** Add a small, cursor-tracked offset to the *child* (icon + text) inside `SpringHoverButton`, in addition to the existing magnetic lean of the pill behind it. All six recording-bar buttons inherit it automatically.

## Background

`packages/screen_recorder/lib/ui/bar/spring_hover_button.dart` already implements a springy "hover pill" behind its child: the pill fades/scales in on enter, leans toward the cursor at a `0.12` factor clamped to ±8 × ±6 px, and flies off on exit. Today the child (icon + label) sits unchanged inside a `Stack`. We want the child to *also* lean toward the cursor on hover, at a smaller range than the pill, producing a layered "depth" effect.

## Decision (from brainstorming)

- **Inner range:** `(rel * 0.06).clamp(±4, ±3)` px — ≈50% of the pill's lean.
- **Inner spring:** stiffness 300 (matches the pill's `_dx`/`_dy`), **zeta 0.9** (calmer than the pill's 0.58 — no perceptible overshoot, so the child reads as anchored).
- **Lifecycle:** enter sets target to the parallax offset (child starts at 0, springs to target — it must not "fly in" the way the pill does, because the icon/text is the visible content); hover-move retargets each event; exit targets 0 (child glides home, only the pill flies off).
- **Press/tap:** child is unaffected; press intensity stays on the pill.
- **Hit-testing:** unchanged — the GestureDetector wraps the outer `Stack`, not the child.

## Components

### `SpringHoverButton` (modified, single file)
`packages/screen_recorder/lib/ui/bar/spring_hover_button.dart`

- Add two springs to `_SpringHoverButtonState`:
  ```dart
  final _innerDx = _Spring(0, stiffness: 300, zeta: 0.9);
  final _innerDy = _Spring(0, stiffness: 300, zeta: 0.9);
  ```
- Add them to the `_onTick` iteration and the settle-check (so the ticker keeps running while they're moving and stops once they settle).
- In `_onEnter`: set targets to `(rel.dx * 0.06).clamp(-4.0, 4.0)` / `(rel.dy * 0.06).clamp(-3.0, 3.0)`. Do **not** seed `.value` from the cursor (unlike the pill, which starts at the entry point and springs to centre) — the child starts at 0 and springs to the target.
- In `_onHover`: same clamp/factor, retarget only.
- In `_onExit`: `targets = 0`. The child glides home; only the pill flies off.
- In `build`: wrap `widget.child` (the second Stack child) in `Transform.translate(offset: Offset(_innerDx.value, _innerDy.value), child: widget.child)`.

No public API change. No new constructor params. No caller migrations.

### Callers (unchanged)
All six `SpringHoverButton(…)` constructions in `packages/screen_recorder/lib/ui/bar/recording_bar.dart` (lines 154, 194, 259, 348, 413, 443) get the effect with zero code change.

## Data flow

```
PointerEnter / PointerHover
        │
        ▼
_centreRel(local)                       — converts pointer to centre-relative coords
        │
        ├─► pill: _dx/_dy.target = rel * 0.12, clamp ±8 × ±6       (existing)
        │
        └─► child: _innerDx/_innerDy.target = rel * 0.06, clamp ±4 × ±3   (NEW)

Ticker (existing)
        │
        ▼
spring.tick(dt) for {_reveal, _scale, _press, _dx, _dy, _innerDx, _innerDy}
        │
        ▼
setState → build
        │
        ├─► pill: Opacity → Transform.translate(_dx/_dy) → Transform.scale → DecoratedBox
        │
        └─► child: Transform.translate(_innerDx/_innerDy) → widget.child
```

## Error handling / edge cases

- **Rapid enter→exit:** springs are stateful but bounded; `_innerDx/_innerDy.target = 0` on exit pulls them home regardless of mid-flight state. Settle check stops the ticker.
- **Cursor not over the child on enter:** `_innerDx.value` starts at 0, target is the (clamped) parallax offset. The child translates a few pixels — no perceptible jump.
- **Tiny buttons:** the clamp (±4/±3) is the safety net. For very small buttons the parallax is effectively bounded by the clamp, not the proportional factor.
- **Press while hovering:** press affects the pill's `_press`/`_scale`; child offset continues to track. No interaction.
- **Hit-testing:** unchanged — the GestureDetector is on the outer `Stack`. The child shifts a few pixels visually, but tap hits land on whichever Stack child the gesture detector covers.

## Testing

Add `packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart` (no existing test). Use Flutter's `TestPointer` to simulate hover/move/exit, drive a few ticker frames via `tester.pump(Duration)`, and assert:

1. **Idle:** the child's enclosing `Transform.translate` has `offset == Offset.zero` (or very close — within ε).
2. **Under hover** with cursor toward the upper-right:
   - the inner offset has **same-sign** components as the cursor (positive dx, negative dy) — *direction*, not exact value.
   - the inner offset magnitude obeys the ±4 / ±3 clamp.
3. **On exit:** after a few hundred ms of pump, the inner offset has trended back toward zero (`.distance < entry-time magnitude`).

Pixel-perfect spring values are deliberately **not** asserted — the curve is allowed to be tuned; the test pins the contract (clamp + direction + settle), not the easing.

## Out of scope

- Pill behavior (fade, scale, press, exit-fly) — unchanged.
- Per-caller variants of the inner range — there's only one feel for the bar.
- Multi-layer parallax (icon vs text moving at different ratios) — single inner layer; YAGNI.
- Any change to `recording_bar.dart`.

## Success criteria

- All 6 recording-bar buttons show a subtle inner shift of icon+text toward the cursor on hover, glide home on exit, at ≈50% of the pill's range.
- No regression to existing pill behavior (manual + the new test).
- `flutter analyze --no-fatal-infos` clean in `packages/screen_recorder`; full app suite green.
