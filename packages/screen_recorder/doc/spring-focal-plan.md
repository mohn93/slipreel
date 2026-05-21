# Spring-Driven Focal — Plan

Replace the EMA + duration-tween focal smoothing in `ZoomFocalController` with a
critically-damped 2nd-order spring so the camera has continuous velocity AND
acceleration (no sudden velocity changes possible), structurally eliminating the
"view jumps when zoomed in" complaint.

## What's being replaced

In `ZoomFocalController.update()`, the chain today is:

```
raw cursor → EMA (target smoothing) → tween (focal lerp) → focal
```

Replace with:

```
raw cursor → critically-damped 2nd-order spring → focal
```

Same input/output contract (`ZoomFocalUpdate(zoom, focal)`), entirely different
dynamics. Spring state is `(position, velocity)` per axis, integrated each
frame with semi-implicit Euler.

## Spring math

Per axis, per frame:
- `ω = 2 / settleTime` (natural frequency)
- `k = ω²` (stiffness, mass = 1)
- `c = 2ω` (damping for critical: ζ = 1, no overshoot)
- `a = -k·(x - target) - c·v`
- `v += a·dt`
- `x += v·dt`

`settleTime` comes from `followDuration` (so the knob keeps the same semantic
meaning: "how long until the camera arrives"). At 700 ms default, the spring
is ~95% settled at ~3 × 700 = 2.1 s after a step, but `dt` is in *video time*
so scrubs/pauses work the same way today's EMA does.

**`dt` source & cap.** Same time source the EMA uses today:
`dt = position − prevPosition`, video-time microseconds. Capped at
**16 ms** (one 60 fps frame) before being fed into the integration —
shorter than the EMA's 50 ms cap because semi-implicit Euler can
overshoot when `dt × ω` is large at stiff settle times. A pause-resume
delivering a 1 s jump would otherwise compress a second of catch-up
into a single unstable step.

**First frame after a snap.** Snap paths (no-active-zoom reset,
first-frame-of-zoom, forceSnap / reverse-scrub) zero `_focalVx` /
`_focalVy` *and* skip the integration step that frame — the spring
holds at the snapped position and the next frame's `dt` (computed
against the newly stamped `_lastUpdatePosition`) drives the first real
integration. Without this, the first post-snap frame has
`prevPosition == null` (or carries a discontinuity-sized gap) and we'd
either crash or step the spring across a junk dt.

## Knobs — keep / remove / repurpose

| Knob | Today | After | Rationale |
|---|---|---|---|
| `followCursor` | Track cursor vs. pin to rect.center | **Keep, unchanged** | Same meaning. |
| `followMode` (bounded / centered / predictive) | Picks target source + deadzone gate | **Keep, unchanged** | Same meaning. |
| `deadzoneRatio` | Trigger box for starting a tween | **Keep, unchanged** | Same meaning — gates whether the spring engages. |
| `predictiveWindow` | Median lookup for predictive mode | **Keep, unchanged** | Doesn't touch the smoother. |
| `followDuration` | Tween duration (`easeInOutCubic` curve) | **Keep, semantics adjusted** | Now = spring settle time. Default 700 ms unchanged. UI label stays "Follow duration"; subtitle reworded. |
| `followSmoothing` (added 2 turns ago) | EMA τ on cursor target | **REMOVE** | The spring is inherently a 2nd-order low-pass — the EMA is now redundant. Two stacked smoothers with different time constants would make the camera unpredictable. |
| `followCurve` override + `CurveEditor` | Replaces `easeInOutCubic` with custom Bezier | **REMOVE** | A spring doesn't have an arbitrary "curve" — its shape is fixed by damping ratio. Curve override is meaningless under the new model. |

## What we lose, and why it's OK

1. **Ramp-synced tween duration** — today's tween shrinks/grows so the focal
   lands at the cursor exactly when the enter ramp ends (and lerps to centre
   exactly when the exit ramp ends). With a spring, the focal might still be
   drifting at ramp boundaries.
   - **Enter ramp**: focal ~63% there at 500 ms ramp end if settle time =
     700 ms. After ramp completes, the spring keeps catching up for another
     ~1 s while the user looks at the zoomed view. This *should* feel like
     "camera settles into its final pose" (which is what cinematic editors
     actually do) rather than abrupt.
   - **Exit ramp**: keep the existing `easeInOutQuad` lerp-to-centre branch
     unchanged. The spring is only active during the hold phase. The exit
     ramp's special-case behaviour is preserved.

2. **`followCurve` library presets** — anyone who set a custom Bezier curve
   loses it. Legacy projects' saved `followCurve` field is read by `fromJson`
   and silently ignored (no schema bump needed since `fromJson` is already
   tolerant of unknown fields once we remove the model field).

3. **`followSmoothing` slider** — the value is loaded from legacy JSON and
   ignored. The UI section vanishes. Anyone who tuned it to 0.0 for "raw
   cursor tracking" gets the spring's settle time only (still smoother than
   today's raw).

## What stays the same

- First-frame snap on zoom region change → snap spring position to target,
  zero velocity.
- Backward-scrub branch (10 ms threshold) → snap spring position to target,
  zero velocity.
- `forceSnap` (hover-scrubbing) → same.
- Exit-ramp `easeInOutQuad` lerp-to-centre → unchanged, special-cased outside
  the spring path.
- Deadzone gate decides whether the spring's target is `cursor` or
  `currentFocal` (i.e., effectively idle).
- Predictive median target source → unchanged.
- Cursor post-processing (despike / end-freeze / state debounce) → unchanged.
- The hold-position cache key (postProcess, position) → unchanged.

## Files touched

1. **`lib/models/zoom_region.dart`**
   - Remove fields: `followSmoothing`, `followCurve`.
   - Remove constructor parameters, `copyWith` entries (including the
     `clearFollowCurve` boolean), `toJson` keys, `==` / `hashCode` entries.
   - `fromJson`: drop the `followSmoothing:` and `followCurve:` constructor
     arguments and the lines that read those keys. Legacy JSONs with the
     old keys still load — Dart's `Map<String, dynamic>` ignores
     unconsulted entries, so no explicit "tolerance" code is needed.

2. **`lib/ui/widgets/zoom/zoom_focal_controller.dart`**
   - Strip `_tweenFrom`, `_tweenTo`, `_tweenStartPosition`, `_tweenDuration`,
     `_emaTarget`, `_applyTargetEma`, `_resolveCurve`, `_emaMaxDtMicros`.
   - **`_tweenDurationFor` fate depends on open Q #1.** Option (a) ⇒ delete
     it entirely (its only job is ramp-sync). Option (b) ⇒ keep it, used
     only to time the in-ramp tween while the spring path is gated off
     during the enter ramp.
   - **`_exitRampWindow` stays regardless** — it powers the exit-ramp
     `easeInOutQuad` lerp-to-centre branch, which the plan keeps unchanged.
   - Add `_focalVx`, `_focalVy` state. Step the spring per axis per frame,
     with `dt` from the same source the EMA uses today (capped at 16 ms).
   - Remove the four `_emaTarget = …` reset sites at today's lines 114
     (no-active-zoom), 126 (first-frame snap), 153 (forceSnap / reverse-
     scrub), and 269 (`reset()`). All four become `_focalVx = _focalVy = 0`
     instead, with the first-frame integration skipped (see Spring math
     "First frame after a snap").
   - Exit-ramp branch untouched. Spring is only active during the hold
     phase (and during enter ramp if option (a) wins).

3. **`lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`**
   - Remove the **Follow smoothing** slider section.
   - Remove the **Follow curve override** toggle and the dependent
     `CurveEditor`.
   - Rewrite **Follow duration**'s subtitle to "≈ how long the camera takes
     to settle on a new target".

4. **`test/ui/widgets/zoom/zoom_focal_controller_test.dart`**
   - **Delete**: `followCurve override shapes the tween progress`,
     `Curves.easeOutCubic ≈ 0.875 at t=0.5` (already updated last round —
     this test goes away entirely).
   - **Delete**: 4 `follow smoothing (EMA)` tests added last turn.
   - **Adapt**: `tween reaches captured target after followDuration with
     easeOutCubic default` → rename to "spring reaches target within ~3×
     settle time" (the existing title's "easeOutCubic default" phrase is
     already stale — the current default is `easeInOutCubic` — so the
     rename also clears that).
   - **Adapt**: `mid-tween retarget keeps elapsed and from but updates to` →
     "spring's target updates each frame, focal chases continuously" (the
     test's intent — "follow the latest cursor" — survives, but with no
     `_tweenFrom`/`_tweenTo` to assert on).
   - **Adapt**: `tween started inside the enter ramp ends exactly when the
     zoom ramp ends` → depends on enter-ramp answer below.
   - **Keep**: all the snap / forceSnap / backward-scrub / first-frame /
     exit-ramp / cache tests.
   - **Add**: new tests — spring snaps on init, spring tracks moving target
     with smooth velocity, spring's velocity is continuous across a cursor
     reversal (no sign-flip discontinuity), spring settles within ~3×
     duration, large-dt step doesn't blow up (verifies the 16 ms cap).

5. **`test/models/zoom_region_json_test.dart`**
   - Remove `followSmoothing` and `followCurve` from the populated
     round-trip test.
   - Remove the `followSmoothing` default assertion.
   - Add a legacy-tolerance test: JSON with a `followSmoothing` key loads
     cleanly (field is ignored, no exception).

## Open questions (to confirm before implementing)

1. **Enter-ramp behaviour** — two options:
   - **(a) Spring during enter ramp too.** Camera converges on cursor
     smoothly but may still be drifting when zoom hits target. Simplest,
     more "cinematic settle" feel. **`_tweenDurationFor` is deleted.**
   - **(b) Tween during enter ramp, spring after.** Keeps the existing
     ramp-synced behaviour where focal lands at cursor exactly when zoom
     completes. Hybrid, more code, no settle drift. **`_tweenDurationFor`
     is kept**, plus a small piece of state to track which mode is in
     flight (tween vs spring) and a handoff at ramp end (snap spring
     position to current focal, zero velocity).

   Recommendation: **(a)**. Less special-casing; residual drift after the
   ramp ends is barely noticeable and matches premium screencast tools.

2. **Damping ratio control** — should we expose a "stiffness/damping" knob
   that lets the user under-damp (slight bounce) or over-damp (heavier lag)?

   Recommendation: **no, ship critical damping only**. It's what "smooth
   camera" means. Add later if anyone wants it.

3. **Knob removal vs. hide**: Hard-remove the model fields, or leave them as
   deprecated-with-warning?

   Recommendation: **hard-remove fields, tolerant `fromJson`**. Old JSONs
   load fine; new JSONs don't write the keys. No deprecation noise.

## Suggested implementation order (one commit each)

1. *(optional)* Add spring step inside `ZoomFocalController` alongside the
   existing tween, gated by an experimental feature flag, so tests stay
   green while we iterate. Can skip and go straight to #2.
2. Rip out EMA + tween from `ZoomFocalController`. Add `_focalVx`/`_focalVy`
   state. Implement the spring step. Snap paths reset velocity.
3. Remove `followSmoothing` / `followCurve` from `ZoomRegion`. Update
   `copyWith`/`toJson`/`fromJson`/`==`. Update the JSON round-trip test.
4. Remove the smoothing slider + curve override section from
   `zoom_context_inspector.dart`. Reword the Follow duration subtitle.
5. Update / delete the affected focal controller tests; add new
   spring-specific tests.
6. `flutter analyze` + `flutter test` green pass.

## Status

- Plan written 2026-05-17.
- Revised 2026-05-17 (post-compact cross-check): added spring `dt`
  source + 16 ms cap, first-frame-after-snap behaviour, the four
  `_emaTarget` reset sites that need to flip to velocity-zero, the
  `_tweenDurationFor` vs `_exitRampWindow` distinction, a cleaner
  `fromJson` cleanup story (no special tolerance code needed), and a
  rename for the stale `easeOutCubic default` test title.
- **Implemented 2026-05-17.** All three open questions resolved with
  the recommended option: (1) spring throughout, (2) critical damping
  only, (3) hard-removed model fields. One design refinement that
  came out of execution: a single 16 ms cap on `dt` would lose the
  remainder of any frame longer than 16 ms (sparse test calls, 30 fps
  playback), so the spring is **sub-stepped at ≤16 ms slices with a
  250 ms total-dt cap** instead. The deadzone gate is **velocity-
  gated** (above `_restSpeedEpsilon = 1 px/s` → bypass) so the old
  "tween in flight, ignore the deadzone" semantic survives without
  an explicit `_inFlight` flag. 511 tests pass, analyze clean
  (pre-existing infos only).
