# Anticipatory Zoom Follow — Design

**Date:** 2026-06-30
**Branch:** `feat/anticipatory-zoom-follow`
**Status:** Approved design, pending implementation plan

## Problem

The zoom camera's **Predictive** follow mode (the "Predictive" chip under *Follow style* in
the zoom inspector) is the user's preferred mode, but it has two symptoms:

1. **The cursor isn't always in view** — the framed viewport can show an area that doesn't
   include the live pointer.
2. **The camera delays behind the mouse** — during sustained motion the camera trails the
   cursor.

### Root cause

Despite the UI labeling its slider **"Lookahead window"**, Predictive does *not* look ahead.
It aims the camera at the **median cursor position over the trailing 1.5 s**
(`medianCursorOver` in `cursor_geometry.dart`, wired in `scene_pass_builder.dart`,
consumed by `PredictiveFollowStrategy` which currently extends `CenteredFollowStrategy`).

A trailing median is **inherently backward-looking**:

- It centers on where the cursor *has been*, so during motion the camera always lags → symptom 2.
- Nothing constrains the *live* cursor to stay inside the framed viewport — the camera centers
  on the dwell point, so a cursor that has moved away sits at or past the frame edge → symptom 1.

The only genuine look-ahead in the system today is the velocity feedforward on the **cursor
sprite** (`CursorMotionController`), which moves the little cursor graphic — not the camera focal.

## Goals

- **Both, balanced:** reduce the lag *and* guarantee the cursor stays in frame, while keeping
  motion smooth/cinematic (not jittery or robotic).
- **Camera feel:** "calm, pan only when needed" — the camera holds steady while the cursor works
  in a central safe-zone and pans only as the cursor heads toward an edge, anticipating with
  velocity so the pointer never reaches the edge (Screen Studio style).

## Non-goals

- No new "glide-track every frame" behavior (the user explicitly chose the calm/deadzone feel
  over continuous tracking; `centered` already serves anyone who wants tight tracking).
- No changes to the enter/exit ramp pan, manual (`followCursor: false`) placement, or the
  cursor-sprite feedforward.
- No redesign of the inspector beyond the slider relabel described below.

## Approach (approved: "Anticipatory deadzone follow + hard keep-in-view")

Three layers in the focal pipeline. Layers 1–2 are the primary mechanism for the redefined
Predictive mode; layer 3 is a universal safety applied to **all** modes.

### Layer 1 — Anticipate (velocity lead)

Predictive's per-frame target is the **velocity-led cursor**:

```
ledCursor = cursor + cursorVelocity * leadTime
```

The deadzone engage/release test and the spring target both use `ledCursor` instead of the raw
cursor. Because the camera aims slightly ahead of motion, it starts panning *before* the pointer
reaches the deadzone edge, eliminating the perceived lag.

`leadTime` is a "feel" constant (default ~150 ms, see Tuning). Lead is naturally bounded: when
the cursor is at rest `cursorVelocity ≈ 0`, so `ledCursor ≈ cursor` and there is no overshoot on
click landings.

### Layer 2 — Deadzone (calm "pan only when needed")

Reuse the existing engage-positional / release-velocity-aware deadzone gate (today's
`BoundedFollowStrategy` logic): the focal holds steady while the (led) cursor sits inside a
centered deadzone box sized `(videoSize / zoom) * deadzoneRatio`; crossing the boundary starts a
spring chase that releases when the cursor comes to rest back inside the deadzone. This gives the
calm feel — the camera doesn't swim for small in-zone movements.

The deadzone is computed against `ledCursor` so anticipation and the calm zone compose: a fast
move breaches the zone earlier (good); a slow nudge inside the zone never starts a chase (calm).

### Layer 3 — Keep-in-view clamp (universal safety net)

After the spring step, constrain the **returned** focal in `ZoomFocalController.update()` (a pure
helper `ZoomFraming.clampFocalKeepCursorInView`):

- Project the **live** cursor into the current viewport. If it would fall outside the viewport
  minus a small `edgeMargin`, nudge the focal the **minimum** amount **per axis** to bring the
  cursor back inside the margin. An axis whose cursor is already in view is returned **verbatim**.
- The pulled axis is clamped to the **reachable focal range** for the current zoom (same
  `ZoomFraming` bounds the transformer uses), so the viewport never leaves the composed canvas.
  Near the true canvas edges the guarantee **degrades gracefully** — geometry cannot keep a
  corner-cursor centered, but the cursor stays as in-view as physically possible.

**Critical implementation properties (learned during implementation):**

1. **Output-only, never mutate the spring state.** The clamp constrains the *returned* focal but
   does NOT write back into `_smoothedFocal`. The spring integrates freely (unclamped, as before —
   the transformer clamps at paint). Mutating the spring state winds up velocity against an
   out-of-reach (screen-corner) cursor and alters bounded/centered dynamics.
2. **Small, viewport-relative, per-axis margin.** `edgeMargin` is a fraction of the *viewport*
   (`canvasDim / z`) per axis — `allowed = (canvasDim/z)·(0.5 − margin)` — NOT a fraction of the
   canvas short side. This makes the safe area zoom-invariant and keeps it strictly **outside** the
   deadzone (default 0.8) so the safety never fights the deadzone/spring during normal follow.
   Default margin **0.04** (4% of the viewport per side → safe area 92% > deadzone 80%).
3. **Forward-step gated.** Applied only when the spring stepped forward this frame; backward-scrub
   and zero-dt re-eval frames (which intentionally freeze the spring) are skipped. Determinism is
   preserved because the `DeterministicFocalTrack` replay and export are forward-only.

Applied to **every** follow mode. It is a true last-resort safety: lead + deadzone keep the cursor
well inside during normal follow, so it fires only on genuine near-edge excursions / fast flicks.

## Architecture / changes

- **`zoom_region.dart` (`FollowMode`):** keep the three modes. Update the `predictive` doc comment
  from "median dwell" to "anticipatory deadzone follow that leads the cursor". The
  `predictiveWindow` field is repurposed as the **look-ahead time** (see Tuning + Migration); the
  `deadzoneRatio` field now also applies to `predictive`.
- **`follow_strategy.dart`:** `PredictiveFollowStrategy` stops extending `CenteredFollowStrategy`
  and becomes a deadzone strategy with velocity lead — structurally a parameterized
  `BoundedFollowStrategy` whose target is `ledCursor`. Keep `BoundedFollowStrategy` (reactive, no
  lead) and `CenteredFollowStrategy` as-is. Factor shared deadzone gate logic so the two deadzone
  strategies don't duplicate the engage/release state machine.
- **`scene_pass_builder.dart`:** remove the `medianCursorOver` branch (lines ~184–188). Predictive
  now receives the same spring-smoothed sprite cursor as the other modes; the lead is applied
  inside the strategy from `cursorVelocity` (already threaded through `resolve`).
- **`cursor_geometry.dart`:** `medianCursorOver` becomes dead code — remove it and its tests.
- **`zoom_focal_controller.dart`:** add the keep-in-view post-clamp after the hold-phase spring
  step (after line ~787), as a pure helper on the framing geometry. No change to enter/exit ramps
  or manual placement.
- **`motion_tuning.dart`:** add `keepInViewEdgeMargin` (see Tuning). The lead time is NOT a
  `MotionTuning` constant — it reuses the per-region `predictiveWindow` field (see below), which
  matches the existing per-region slider and avoids a rename cascade.
- **`zoom_context_inspector.dart`:** relabel the Predictive slider from **"Lookahead window"** to
  **"Look-ahead time"**; change its range/subtitle/reset to lead-time semantics (see Tuning).
  Show the **"Deadzone size"** slider for `predictive` as well as `bounded`.

## Tuning

Defaults (tune during implementation against live preview):

| Knob | Home | Default | Range | Meaning |
|---|---|---|---|---|
| Lead time | per-region `predictiveWindow` (repurposed) | 150 ms | 80–250 ms (UI slider) | How far ahead Predictive aims (`cursor + v·leadTime`). |
| `keepInViewEdgeMargin` | `MotionTuning` | 0.04 (4% of the **viewport**, per axis) | (constant, no UI) | Min gap kept between the live cursor and the viewport edge. Viewport-relative so it stays outside the deadzone at every zoom. |

Per-region (existing): `deadzoneRatio` (now applies to predictive too), `followDuration`
(spring settle time). The deadzone must stay **smaller** than the keep-in-view safe area
(deadzone default 0.8 vs safe area ~0.84) so the two don't fight; with lead the deadzone is
breached first, leaving the clamp as a rarely-firing backstop.

## Migration / compatibility

- **Behavior change:** existing projects whose zoom regions use `FollowMode.predictive` adopt the
  new anticipatory behavior instead of median dwell. This is the intended fix (median *is* the
  laggy/lost-cursor behavior). Accepted by the user.
- **`predictiveWindow` field:** persisted regions carry an old value defaulting to 1500 ms, which
  is nonsensical as a look-ahead time (1.5 s of lead would massively overshoot). The constructor
  **clamps `predictiveWindow` into `[80 ms, 250 ms]`** (and a missing key falls back to the new
  150 ms default), so legacy values are pulled into a sane lead range deterministically — a stored
  1500 ms becomes 250 ms. The JSON key (`predictiveWindowMicros`) and Dart field name are both
  retained for compatibility and to avoid a rename cascade; only the interpretation, default, and
  clamp change.

## Determinism

All three layers are pure functions of `(cursor, cursorVelocity, focal, zoom, framing)`. The
keep-in-view clamp lives inside `ZoomFocalController.update()`, which is the single path replayed
by `DeterministicFocalTrack.build` (via `ScenePassBuilder.build`) for scrub-paused, scene-blur,
and export. So **live play, scrubbing, and export stay byte-identical** — no preview≠export drift.

## Testing

- **Unit — `PredictiveFollowStrategy`:** led target = `cursor + v·leadTime`; deadzone engage on
  led-cursor exit; release on rest-inside-deadzone; zero velocity ⇒ no lead (no overshoot).
- **Unit — keep-in-view clamp:** cursor pushed past margin ⇒ focal nudged minimally to restore
  margin; cursor well inside ⇒ no-op; cursor near canvas edge ⇒ nudge clamped to reachable bounds
  (graceful degradation, viewport stays on canvas). Applies to bounded/centered/predictive.
- **Determinism:** a focal track built via `DeterministicFocalTrack` over a synthetic recording
  equals the live `update()` sequence frame-for-frame, including the clamp.
- **Regression:** bounded and centered behavior unchanged except the added keep-in-view clamp;
  enter/exit ramp and manual placement untouched (existing golden/byte-identical tests stay green).
- **Manual / runtime:** drive the editor (flutter-qa + `ext.slipreel`) on a fast-cursor recording;
  confirm the cursor stays in frame and the camera leads rather than trails. Export pixel golden
  on one Predictive region.

## Open implementation questions (resolve in the plan, not blocking design)

- Exact default `cursorLeadTime` and `keepInViewEdgeMargin` values — derive from live preview.
- Whether the keep-in-view clamp should be velocity-aware (slightly larger margin when moving) or
  a flat margin. Start flat; revisit only if the backstop reads as a hard stop.
