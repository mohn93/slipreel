# Zoom Movements Library — Phase 2 Design

**Date:** 2026-07-01
**Status:** Design — pending user review
**Issue:** #12 (3D zoom effect: perspective/parallax "3D movement" zoom)
**Branch:** `feat/zoom-movements-library`
**Builds on:** Phase 1 (3D zoom tilt, PR #34) — `docs/superpowers/specs/2026-06-29-3d-zoom-tilt-phase1-design.md`

## Summary

Phase 1 gave zooms depth: a static 3D perspective **tilt** that leans a content
panel toward the viewer at full zoom. It is still a *static hold* — once the
zoom settles, the camera is frozen until the exit ramp.

Phase 2 makes that held camera **move**. A **Movement** is a named, tasteful
camera motion — push-in, orbital sweep, slow drift — that plays during the
zoom's hold, giving the "launch video" feel of a camera that's alive rather
than parked. It is the direct realization of what the Phase 1 spec deferred:
"sequences of the same 3D matrix Phase 1 produces."

Movements are **parametric presets** (a *library* you pick from), not a
keyframe editor. Each preset resolves to a pure, time-parameterized transform
folded into the existing Phase 1 matrix builder, so preview and export stay
identical and flat/None zooms stay byte-identical to today.

## Goals

- A zoom can carry an optional **Movement** chosen from a small curated library
  (None / Push-in / Sweep / Drift), with a **Subtle / Dramatic** intensity.
- The movement plays over the zoom's **hold window** (between the enter and exit
  ramps), fading in and out with the ramp so there is never a pop.
- **Direction is automatic** (derived from the focal's position in the frame,
  the same signal Phase 1 tilt uses). No manual-direction UI in v1.
- **Preview and export render identically** — movement is a pure function of
  source position, so it drops into the deterministic focal track for free.
- **Zero regression:** a zoom with no movement (None) is byte-identical to
  today's Phase 1 output. Existing saved projects load as None.
- The engine is built **keyframe-ready** internally (presets sample an eased
  curve), so a future phase can expose editing without a rewrite.

## Non-goals (Phase 2)

- **No keyframe editor** — no per-key add/drag/delete UI, no per-segment easing.
  Presets are the only surface.
- **No standalone / cross-zoom movement objects** — a movement belongs to one
  zoom region; it does not span multiple zooms or exist without a zoom. (That is
  the eventual "camera path" dream; out of scope.)
- **No Handheld float or Hero spin** — the cheesier, higher-risk moves. Deferred
  to a later phase once the framework is proven.
- **No manual-direction override UI** — the model supports it (mirrors tilt's
  manual angles) but v1 ships auto-only.
- **No background parallax / independent background motion** — background stays
  static under the moving panel, same constraint as Phase 1.
- **No project-wide default-movement setting** — per-zoom choice is enough.

## Decisions (resolved in brainstorming)

| Question | Decision |
| --- | --- |
| What is a movement? | A per-region property on `ZoomRegion`, next to `Tilt3D` |
| Parameterization | Fixed parametric presets; engine keyframe-ready under the hood |
| v1 library | None + Push-in + Sweep + Drift |
| Intensity | Subtle / Dramatic (reuse tilt vocabulary) |
| Direction | Auto-derived from focal position; no manual UI in v1 |
| Default for new zooms | **None** (opt-in) — continuous motion is more assertive than a static tilt |
| Existing projects | Load as None (absent JSON key) |
| Follow-cursor interaction | Push-in/Sweep compose with follow + manual; Drift = manual zooms only |

## The library (v1)

Each preset animates a distinct channel of the transform, so building all three
exercises the whole engine.

| Move | Animated channel | Behavior | Applies to |
| --- | --- | --- | --- |
| **None** | — | Static hold (today's Phase 1 behavior) | all (default) |
| **Push-in** | scale | Scale creeps up smoothly across the hold: ×1.06 (Subtle) / ×1.12 (Dramatic) of the settled zoom | follow + manual |
| **Sweep** | tilt yaw | Tilt Y arcs slowly across the hold (an orbital pan). Auto direction from focal side; magnitude Subtle/Dramatic | follow + manual |
| **Drift** | focal | Focal pans slowly one direction (a slow reveal). Auto direction from focal position | **manual only** |

**Drift is manual-only** because follow-cursor zooms already animate the focal
to track the cursor; a focal-shifting movement would fight the anticipatory
follow. Push-in and Sweep touch scale/tilt (orthogonal to the focal) and compose
with both. The inspector hides Drift for follow-cursor zooms.

## Architecture

### Model: `ZoomMovement`

New value type in `packages/slipreel_engine/lib/models/zoom_movement.dart`,
mirroring `Tilt3D`:

```dart
enum ZoomMovementKind { none, pushIn, sweep, drift }
enum ZoomMovementIntensity { subtle, dramatic }

class ZoomMovement {
  const ZoomMovement({
    this.kind = ZoomMovementKind.none,
    this.intensity = ZoomMovementIntensity.subtle,
  });

  final ZoomMovementKind kind;
  final ZoomMovementIntensity intensity;

  bool get isActive => kind != ZoomMovementKind.none;

  /// Pure resolve for one frame. All outputs are ADDITIVE deltas on top of the
  /// settled (Phase 1) transform, pre-scaled by [rampGate] so they fade with
  /// the zoom ramp (0 at ramp start/end, full at settled).
  ZoomMovementSample resolveAt({
    required double holdProgress, // 0 before hold, 0->1 across hold, 1 after
    required double rampGate,     // the same [0,1] progress tilt uses
    required Offset normalizedFocal, // focal offset from canvas center, [-1,1]
  });
}

class ZoomMovementSample {
  final double scaleMul;        // multiply the settled zoom factor (1.0 = none)
  final double extraTiltXRad;   // added to the tilt angles
  final double extraTiltYRad;
  final Offset focalOffsetPx;   // added to the focal (canvas px), manual-only moves
}
```

- `copyWith`, `==`/`hashCode`, `toJson`/`fromJson` — same shape as `Tilt3D`.
- `resolveAt` for `none` returns the identity sample (scaleMul 1, zero deltas).
- Preset magnitudes are compile-time constants in this file (like the tilt
  `kTiltSubtleMaxDeg` / `kTiltDramaticMaxDeg` constants), tuned per intensity.

### Curve & timing

- **`holdProgress`** is computed by the caller from the region timing:
  `holdStart = startTime + enterDuration`, `holdEnd = endTime - exitDuration`.
  `holdProgress = ((position - holdStart) / (holdEnd - holdStart)).clamp(0, 1)`.
  If the hold window is degenerate (enter+exit consume the region), the movement
  contributes ~nothing (progress pinned) — no whip on tiny zooms.
- Presets sample an **eased curve** of `holdProgress` (ease-in-out), so motion
  starts and ends gently. This eased sample is the internal "keyframe track"
  that a future editor could expose.
- **`rampGate`** is the existing zoom-ramp progress (`(z-1)/(zoomLevel-1)`,
  clamped) that Phase 1 tilt already computes. Multiplying every movement delta
  by it means movement is zero during ramp-in/out and full only at the settled
  hold — no discontinuity as the zoom enters or exits.
- **Duration-awareness:** Push-in/Sweep/Drift totals are the *maximum* reached
  at `holdProgress == 1`. Because short holds still span 0→1, an eased curve
  keeps a short hold's motion gentle; if playtesting shows short auto-zooms move
  too fast, cap the effective total by `min(1, holdSeconds / kRefHoldSeconds)`.
  (Implementation note, not a required knob for v1.)

### Wiring into `getTransform`

`ZoomTransformer.getTransform` (in `zoom_transformer.dart`) already computes `z`,
`progress`, the focal, and the framing. Movement folds in right there:

```
sample = region.movement.resolveAt(holdProgress, rampGate: progress, normalizedFocal: ...)
z'      = z * sample.scaleMul
focal'  = focal + sample.focalOffsetPx   // (canvas px)
// recompute pCenterRel with focal' and z'
angles' = tilt.resolveAngles(...) with (extraTiltX/Y added)
return perspectiveTilt(angles'.x, angles'.y).multiplied(base(z', focal'))
```

- When `movement.kind == none`, the sample is identity and the returned matrix
  is **byte-identical** to Phase 1 — guarded by an early `if (!movement.isActive)`
  fast path to guarantee it.
- The same consumers that read the transform today (`PlaybackCanvas` preview,
  `FrameCompositor` export, `SceneBlurOverlay`) get movement for free because
  it's inside `getTransform` / the focal it feeds.

### Determinism

Movement is a **pure function of source position** (`holdProgress` and
`rampGate` both derive from `position` and the region's fixed timing; no state,
no path dependence). It therefore composes with `DeterministicFocalTrack`
exactly like tilt does: preview-play == scrub == export by construction. This is
the property that made Phase 1 safe, preserved deliberately.

Note the anticipatory-follow lesson (`shouldUseDeterministicFocal` → always true
for follow zooms): movement adds no new statefulness, so that invariant holds
unchanged.

### UI: zoom inspector

In `zoom_context_inspector.dart`, below the existing 3D/tilt controls:

- A **Movement** picker: None / Push-in / Sweep / Drift.
- An **intensity** segmented control (Subtle / Dramatic), shown only when a
  movement other than None is selected.
- **Drift is omitted** from the picker for follow-cursor regions.
- Editing a region's movement flows through the existing
  `EditorProjectController` region-update path (same as tilt edits), so undo,
  persistence, and preview refresh come for free.

## Data flow

1. User picks a movement + intensity in the inspector →
   `EditorProjectController` updates the `ZoomRegion.movement` field.
2. On every rendered frame, the preview/export builds the transform via
   `ZoomTransformer.getTransform`, which now folds the movement sample in.
3. Persistence serializes `movement` in the region JSON (absent ⇒ None on load).

## Error handling / edge cases

- **Degenerate hold** (enter+exit ≥ duration): `holdProgress` pins; movement
  contributes ~nothing. No crash, no whip.
- **Drift on a follow zoom** (e.g. hand-edited JSON): the resolve still runs, but
  the inspector never offers it; if present, it applies as a focal offset — we
  clamp the resulting focal through the existing `clampFocalToBounds` so it can't
  push the viewport off the video.
- **Movement + manual placement**: Push-in re-magnifies about the placed point
  (uses `focal'` through the same `centerOffsetInPlace` path) — stays in place,
  no lurch.
- **Absent JSON key / unknown enum name**: `fromJson` defaults to None / Subtle
  (same defensive parse as `Tilt3D.fromJson`).

## Testing strategy

Engine unit tests (`packages/slipreel_engine/test/`):

- **`zoom_movement_test.dart`** — `resolveAt` endpoints (identity at
  holdProgress 0 and when rampGate 0), monotonic eased curve, per-move channel
  isolation (Push-in only sets `scaleMul`; Sweep only `extraTiltY`; Drift only
  `focalOffsetPx`), None == identity sample, intensity ordering
  (dramatic magnitude > subtle), JSON round-trip + absent-key migration.
- **`zoom_transformer_movement_test.dart`** — with `movement.none` the matrix is
  identical to the pre-movement path (regression guard); a Push-in at
  holdProgress 1 yields a larger effective scale than at holdProgress 0; ramp
  gating drives the movement delta to zero at ramp start.
- **Determinism** — sampling the transform from `DeterministicFocalTrack` at a
  set of positions equals `getTransform` at the same positions for each move
  (preview == export).
- **Golden/pixel parity** — one representative move (Sweep) rendered through the
  preview compositor vs the export compositor at a mid-hold frame match
  (`@TestOn('mac-os')`, consistent with existing goldens).

Recorder tests (`packages/screen_recorder/test/`):

- Inspector shows the movement picker; Drift hidden for follow zooms, shown for
  manual zooms; selecting a movement updates the region and reveals the
  intensity control.

## Rollout / phasing within Phase 2

Implementation order (each independently testable):

1. `ZoomMovement` model + resolve math + unit tests (no rendering yet).
2. Fold into `getTransform` + transformer/determinism tests (regression guard
   for None first, then the three moves).
3. Inspector UI + recorder tests.
4. Golden parity + live visual pass, then finish-branch → PR.

Deferred to a future phase (Phase 2.1+): Handheld float, Hero spin, manual
direction UI, keyframe editing, cross-zoom camera paths, background parallax.
