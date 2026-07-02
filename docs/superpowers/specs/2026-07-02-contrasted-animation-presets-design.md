# Contrasted Animation Presets — Design

**Date:** 2026-07-02
**Status:** Design — approved in brainstorming
**Branch:** `feat/contrasted-animation-presets`
**Problem:** The Animation tab's presets are nearly indistinguishable. Cursor
presets (Smooth/Medium/Rapid/None) differ only in spring phase lag, and the
velocity feedforward halves those differences to ~one frame between adjacent
presets. Screen presets (Focused/Smooth) differ only in ramp length with
same-family ease-out curves.

## Diagnosis (measured)

Cursor presets are critically-damped springs whose only differing parameter is
stiffness (160/380/900/snap → phase lag τ ≈ 158/103/67/0 ms). The global
velocity feedforward (strength 0.5, `MotionTuning.cursorFeedforwardStrength`)
cancels half of τ during motion, compressing visible lag to ≈79/51/33/0 ms —
adjacent gaps of ~20–30 ms, about one frame at 30 fps. All presets share
damping ratio 1.0, so there is no character difference either: same motion,
slightly different delay.

Screen presets are correctly wired everywhere (preview + export both apply
`rampCurve` and `rampDurationScale`), but both curves are ease-out cubics; the
only perceptible lever is ramp length (0.55× vs 1.4×).

Coupling: the camera focal chases the cursor **sprite**
(`ScenePassBuilder` feeds `motionSample.screenPos` to the focal controller),
so cursor-preset changes also shift camera feel. The universal keep-in-view
clamp (anticipatory-follow work) bounds the risk: even a very lazy sprite can
never drag the cursor out of frame.

## Goals

- Each preset is **recognizably different in a blind A/B** at normal playback:
  distinct character (how it moves), not just distinct delay.
- Medium stays the balanced reference (unchanged); None stays the raw grid.
- Preset count, names, and JSON serialization unchanged.
- Preview == export (constants only; no new statefulness).
- Remove dead code found in review (`CursorAnimationStyle.smoothing`).

## Non-goals

- No preset lineup changes (rename/merge/cut) — that's a possible follow-up
  (option C from brainstorming).
- No per-preset UI knobs beyond what exists.
- No change to the feedforward fade mechanism (band stays global 200–800 px/s).
- No camera/follow-strategy changes.

## Design

### 1. Cursor presets — three levers per preset

Each `CursorAnimationStyle` now owns stiffness + damping ratio + feedforward
strength (new `feedforwardStrength` getter on the style extension, exposed via
`CursorAnimationConfig.feedforwardStrength`):

| Preset | Stiffness | Damping ζ | Feedforward | Visible lag τ·(1−ff) | Character |
|---|---|---|---|---|---|
| Smooth | **90** | **0.8** | **0.25** | ≈126 ms | floaty, soft arcs, ~1.5% overshoot at stops |
| Medium | 380 (unchanged) | 1.0 | 0.5 | ≈51 ms | balanced chase (reference, unchanged) |
| Rapid | **1400** | 1.0 | **0.85** | ≈8 ms | locked to the real path, micro-smoothed |
| None | snap | — | — | 0 | raw recorded grid (unchanged) |

Adjacent visible-lag gaps: ~75 / ~43 / ~8 ms (vs today's ~28 / ~18 / ~33 ms),
plus Smooth gains a distinct motion signature (underdamped roundness).

`CursorMotionController.update` reads the strength from the **config** (the
preset) instead of `tuning.cursorFeedforwardStrength`. The `MotionTuning`
field stays (debug playground / custom tuning variants reference it) but the
production path no longer reads it. τ is already computed from the spring
(`2·ζ·√(m/k)`), so the underdamped Smooth τ falls out correctly.

Click accuracy: `isClicked`/click effects sample the **raw** recording, and
ζ=0.8 overshoot is ≈1.5% of step size — clicks still read as landing on
target. Camera coupling is intentional: Smooth = lazier camera, Rapid =
tighter; keep-in-view guarantees the cursor stays framed.

### 2. Screen presets — opposite curve shapes + wider spread

| Preset | rampDurationScale | rampCurve | badgeDuration | Character |
|---|---|---|---|---|
| Focused | **0.5** | **`Cubic(0.2, 0, 0, 1)`** | **140 ms** | instant acceleration, hard settle — snaps and locks |
| Smooth | **1.7** | **`Cubic(0.65, 0, 0.35, 1)`** | **600 ms** | pronounced ease-in-out — winds up, glides, soft-lands |

The ease-in start on Smooth is the perceptible signature. Duration spread
widens from 2.5× to 3.4× (≈250 ms vs ≈850 ms on a default 500 ms ramp). The
existing proportional squeeze for short regions is untouched. Badge curves
stay (`easeOutCubic` / `easeInOutCubic`).

### 3. Cleanup (dead code found in review)

- Delete `CursorAnimationStyleData.smoothing` (0.09/0.18/0.40/1.0) — the
  focal controller no longer takes a smoothing factor; nothing reads it.
- Fix the stale doc comment on `CursorAnimationStyle` claiming it maps to
  `ZoomFocalController.update`'s smoothing.
- Update the picker hover-demo `previewCurve`/`previewDuration` so the demo
  tiles honestly preview the new feels (Smooth demo shows the float; Rapid
  near-instant). Demo-only; no engine effect.

### 4. What does not change

Preset names/count, `toJson`/`fromJson` (preset-name strings), the FIR legacy
table (JSON round-trip only), the feedforward fade band and its smoothstep,
`MotionSpring`/`SpringConfig` model shapes, `None` grid-snap behavior, the
sprite spring's forward-integration/reset semantics (constants only ⇒ the
existing preview==export story is untouched).

## Error handling / edge cases

- Underdamped Smooth on a scrub: backward steps already reset the spring to
  raw — no ring on scrub.
- τ formula with ζ=0.8 at k=90 gives ≈169 ms (vs 211 ms were it critically
  damped at that stiffness) — the feedforward lead uses the same formula, so
  compensation stays consistent with the actual spring.
- Legacy projects: preset-name JSON unchanged; a saved "smooth" project simply
  feels more cinematic after the update (intended product change).

## Testing

- `animation_style_test`: per-preset assertions — stiffness/ff ordering across
  presets, ζ<1 only for Smooth, visible-lag `τ·(1−ff)` gaps ≥40 ms between
  adjacent (non-None) presets, `smoothing` getter gone (compile-level).
- `cursor_motion_controller` tests: strength now sourced from config — assert
  a Smooth vs Rapid step response diverges measurably (e.g. position at
  t=100 ms differs by a real margin), and Smooth overshoots its target by
  >0% and <4% on a step.
- Existing suites re-run; expectations pinned to old constants updated.
- **Live feel session before merge** (release build): user A/Bs all presets on
  a real recording; constants are taste calls and may be re-tuned in place.

---

## Addendum (2026-07-02, post live-feel session): geometric path smoothing for Smooth

**Feedback:** the re-tuned Smooth still "wiggles with hand jitter" — the spring
delays the raw path but reproduces its geometry (every micro-movement
survives, just later). The user wants the *path itself* idealized.

### Mechanism

New pure sampler in `cursor_geometry.dart`:

```dart
CursorPosition? smoothedCursorAt(
  CursorRecording recording,
  Duration t,
  CursorPostProcess cfg,
  Duration sigma,
)
```

Gaussian-weighted average of `cursorAtFiltered` over a symmetric time window:
9 taps at `t + k·(σ/2)` for `k = −4..4`, weights `exp(−k²/8)` normalized.
Only **x/y** are smoothed; `isClicked`/`state`/`timestampMicros` come from the
center tap (raw click semantics preserved). Null taps are dropped and the
weights renormalized; a null center returns null. `sigma == 0` returns the
center tap unchanged (identity bypass). Properties:

- **Pure function of position** → deterministic; scrub == play == export (the
  focal track replays the same code).
- **Symmetric window** → smooths geometry without adding phase lag (looks
  ahead as much as behind) — unlike a softer spring.
- **At-rest exact** → averaging a stationary segment returns the point;
  click landings stay truthful.

### Wiring

`CursorAnimationStyle.pathSmoothingSigma`: Smooth **80ms**, Medium/Rapid/None
`Duration.zero` (byte-identical bypass — Medium stays the reference). Exposed
via `CursorAnimationConfig.pathSmoothingSigma`. In
`CursorMotionController.update`, the chase target and the scene-velocity
estimate sample `smoothedCursorAt` when sigma > 0, else `cursorAtFiltered`
exactly as today. Snap mode (None) untouched.

### Smooth preset recipe (amended)

Geometry now carries the character, so the spring firms up from the
heavy-trail 90/ζ0.8 to **`MotionSpring(stiffness: 180, damping: 0.85)`**
(τ·(1−ff) ≈ 95ms — keeps the ≥40ms visible-lag gap to Medium; overshoot
≈0.6%, a hint of float). Feedforward stays 0.25. All feel constants remain
live-tunable.

### Accepted trade-off

A click during fast motion renders the sprite slightly inside a cut corner
(same divergence class as spring lag; the velocity fade settles the sprite on
the true spot for deliberate clicks).

### Testing (addendum)

Smoother: zigzag jitter attenuation (≥60% amplitude reduction), corner
rounding bounded, at-rest identity, σ=0 identity, query-order determinism,
null-edge handling. Controller: Smooth path variance on a jittery synthetic
recording drops vs Medium; sigma=0 presets bypass to `cursorAtFiltered`.
