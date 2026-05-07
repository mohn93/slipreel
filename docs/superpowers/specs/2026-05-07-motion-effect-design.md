# Motion Effect Design

**Date:** 2026-05-07
**Status:** Approved (per-section), pending file review.

## Goal

Wire the existing Animation-tab `motionBlur` slider (currently labeled
"Coming soon — value is captured but not yet rendered") to actually
render directional motion blur on the cursor and on the screen
composition, in both the playback preview and the exported video.

## Background

The slider is already plumbed end-to-end:

- `animation_tab.dart:193-205` — the slider widget.
- `inspector_panel.dart:58-99` — prop-drilled through the panel.
- `playback_screen.dart:81,158,194,697,706` — held in screen state and
  saved to the editor project sidecar.
- `editor_project_state.dart:25,43,54,70,117-118` — JSON
  serialize/deserialize with default 0.

Nothing reads it during rendering. This spec wires it up.

## Non-goals

- True velocity-vector directional screen blur (would need a fragment
  shader). Anisotropic Gaussian is the v1 trade-off.
- Per-component sliders ("Advanced motion blur settings" stays
  collapsed with the existing "Coming soon" body for v1).
- Scale-derivative radial blur during pure-scale zoom moments.
- Per-zoom-region motion-blur overrides.

## Architecture

### Slider semantics

The 0-1 slider value is the *intensity ceiling*. Effective per-frame
blur is

```
effective = slider × clamp(speed / referenceSpeed, 0, 1)
```

so a stationary cursor at slider=1 gets zero blur, and the blur ramps
up with measured speed.

| Surface | referenceSpeed (px/s) | maxReachPx |
| --- | --- | --- |
| Cursor | 2000 | 12 |
| Screen | 800 | 10 |

When `effective < 0.05`, the surface short-circuits to its existing
single-stamp/no-filter rendering — avoids spending a `saveLayer` on
imperceptible blur.

### Two surfaces, two implementations

**Cursor — multi-stamp directional.** The cursor sprite is small and
we own its drawing entirely (`CursorOverlayPainter`), so we stamp the
sprite N times along its in-scene velocity vector with tapered alpha.
Real directional streak. Identical code path in preview and in
`frame_compositor`'s export.

**Screen — anisotropic Gaussian via `ImageFilter.blur(sigmaX, sigmaY)`.**
Reason: the screen layer contains a `VideoPlayer` (a platform
`Texture`). Multi-stamping a Texture across N layers fights Flutter's
layer caching and is fragile inside `frame_compositor`'s
`PictureRecorder` path. Anisotropic Gaussian, with
`sigmaX = |vx|/refSpeed × maxReach × intensity` and
`sigmaY = |vy|/refSpeed × maxReach × intensity`, gives a
directional-feeling blur on axis-aligned pans (the dominant case:
horizontal cursor follows, vertical zoom enters), and works
identically as a Flutter `ImageFiltered` widget in preview and a
`Paint..imageFilter = ...` over a `saveLayer` in `frame_compositor`.

Trade-off: on a true 45° pan the blur looks like a soft cloud rather
than a sharp 45° streak. Acceptable for v1; revisit with a fragment
shader if needed.

### Velocity sources

- **Cursor.** `CursorMotionController` already smooths the cursor
  position via FIR. Extend `CursorMotionUpdate` with
  `velocityPxPerSec` computed as
  `(currentSmoothedPos − previousSmoothedPos) × (1e6 / Δt.inMicroseconds)`.
  Returns `Offset.zero` on first call, on backward scrubs, and when
  the previous-frame state is missing.
- **Screen pan.** New `ScreenPanVelocityTracker` (stateful, idempotent
  on duplicate `position` calls — same pattern as
  `ZoomFocalController`). Holds last frame's `Matrix4` translation
  and position; `update(transform, position)` returns translation
  velocity in totalSize-px/sec.

### Render order

Cursor is part of the screen composition, so:

1. Cursor multi-stamps itself along its **in-scene velocity** (cursor
   blur baked into the composition).
2. The whole screen composition (cursor included) gets wrapped in the
   anisotropic `ImageFilter` using **zoom-pan velocity**.

Cursor blur and screen blur use independent velocity sources, so the
cursor never gets double-blurred:

| Cursor moves | Screen pans | Result |
| --- | --- | --- |
| no | no | sharp |
| yes | no | cursor blur only |
| no | yes | screen blur only |
| yes | yes | each blur applied along its own velocity |

## File layout

| File | Change |
| --- | --- |
| `lib/effects/motion_blur_samples.dart` | **New.** Pure function `computeMotionBlurSamples(...)` returning `(count, stepPx, alphas[])`. |
| `lib/effects/screen_pan_velocity_tracker.dart` | **New.** `ScreenPanVelocityTracker` class. |
| `lib/effects/motion_blur_screen.dart` | **New.** Pure function `screenBlurSigma({velocity, intensity, refSpeed, maxReach})` — shared by preview and export so the sigmas can't diverge. |
| `lib/ui/widgets/zoom/cursor_motion_controller.dart` | Extend `CursorMotionUpdate` with `velocityPxPerSec`. |
| `lib/ui/widgets/cursor_overlay_painter.dart` | Add `velocityPxPerSec` + `motionBlurIntensity` params; multi-stamp in `paint()`. |
| `lib/ui/widgets/zoom/playback_canvas.dart` | Wrap composition in `ImageFiltered` when screen-blur active; pipe cursor velocity + intensity to painter. New `motionBlur` widget prop. |
| `lib/export/frame_compositor.dart` | Mirror preview's screen `saveLayer + ImageFilter`; pass cursor velocity + intensity into `_paintCursor`. Owns a `ScreenPanVelocityTracker`. |
| `lib/ui/widgets/inspector/tabs/animation_tab.dart` | Drop "Coming soon — value is captured but not yet rendered." parenthetical from the slider subtitle. |
| `lib/ui/screens/playback_screen.dart` | Pass `_motionBlur` into `PlaybackCanvas` (was previously held as state but never read by the canvas). |
| `lib/state/editor_project_state.dart` | No change. Already persists `motionBlur`. |

## Components

### `MotionBlurSamples` (pure)

```dart
class MotionBlurSamples {
  final int count;            // ≥ 1; count == 1 means no blur (head-only)
  final Offset stepPx;         // per-stamp offset (anti-velocity direction)
  final List<double> alphas;   // length=count; sums to 1.0
}

MotionBlurSamples computeMotionBlurSamples({
  required Offset velocityPxPerSec,
  required double sliderIntensity,        // 0..1
  required double referenceSpeedPxPerSec, // 2000 cursor / 800 screen
  required double maxReachPx,             // 12 cursor / 10 screen
  int maxStamps = 8,
});
```

Returns `count=1, stepPx=Offset.zero, alphas=[1.0]` whenever
`sliderIntensity == 0`, velocity speed is below 1 px/s, or
`slider × speed/ref < 0.05`. Otherwise:

```
effective = clamp(slider × speed / referenceSpeed, 0, 1)
count     = 1 + round((maxStamps − 1) × effective)
stepPx    = −v̂ × (effective × maxReachPx) / max(1, count − 1)
alphas[i] = (i + 1) / Σ(j+1 for j in 0..count-1)   // tail i=0, head i=count-1
```

Alphas linearly tapered from `1/Σ` (oldest tail) to `count/Σ` (head)
and normalized to sum to 1 — energy-preserving, so the surface
doesn't change perceived brightness when blur kicks in.

### `ScreenPanVelocityTracker`

```dart
class ScreenPanVelocityTracker {
  Offset update({required Matrix4 transform, required Duration position});
  void reset();
}
```

Holds `_lastTranslation`, `_lastPosition`, `_lastResult`. Idempotent
on duplicate `position` calls (returns `_lastResult` without
advancing state). On a position that is strictly less than the last
seen position (scrubbing backwards), returns `Offset.zero` rather
than producing a negative-Δt blowup. On the first call after
construction or `reset()`, returns `Offset.zero`.

Translation is read from `transform.entry(0, 3)`, `transform.entry(1, 3)`.

### `CursorMotionUpdate` extension

```dart
class CursorMotionUpdate {
  const CursorMotionUpdate({
    required this.screenPos,
    required this.isClicked,
    required this.velocityPxPerSec,
  });
  final Offset screenPos;
  final bool isClicked;
  final Offset velocityPxPerSec;
}
```

In `CursorMotionController.update()`, after computing the smoothed
`screenPos`, the controller now also tracks `_lastScreenPos` and
`_lastPosition`. Velocity is

```dart
if (_lastPosition != null && position > _lastPosition!) {
  final dt = (position - _lastPosition!).inMicroseconds;
  velocity = (screenPos - _lastScreenPos!) * (1e6 / dt);
} else {
  velocity = Offset.zero;
}
```

`reset()` clears `_lastScreenPos` and `_lastPosition` along with the
existing caches.

### `CursorOverlayPainter` extension

```dart
CursorOverlayPainter({
  ...existing,
  this.velocityPxPerSec = Offset.zero,
  this.motionBlurIntensity = 0,
});
```

In `paint()`:

```dart
final samples = computeMotionBlurSamples(
  velocityPxPerSec: velocityPxPerSec,
  sliderIntensity: motionBlurIntensity,
  referenceSpeedPxPerSec: 2000,
  maxReachPx: 12,
);

if (samples.count == 1) {
  // existing single-call path
  paintCursorWithEffects(canvas, position: widgetPos, ...);
  return;
}

final stampBounds = Rect.fromCircle(
  center: widgetPos,
  radius: pxDiameter + samples.stepPx.distance * (samples.count - 1),
);
for (var i = 0; i < samples.count; i++) {
  final dx = samples.stepPx.dx * (samples.count - 1 - i);
  final dy = samples.stepPx.dy * (samples.count - 1 - i);
  canvas.saveLayer(
    stampBounds,
    Paint()..color = Colors.white.withOpacity(samples.alphas[i]),
  );
  canvas.translate(dx, dy);
  paintCursorWithEffects(canvas, position: widgetPos, ...);
  canvas.restore();
}
```

`saveLayer` with `Paint..color = Colors.white.withOpacity(α)` is
Flutter's documented idiom for layer-alpha; Skia uses the Paint's
alpha when restoring. Order: tail painted first (i=0, lowest
alpha), head painted last (i=count-1, full reach offset 0).

`shouldRepaint` adds the two new fields.

### Preview wiring (`playback_canvas.dart`)

Add a private field `final _screenPanTracker = ScreenPanVelocityTracker()`.
Add a new widget prop `final double motionBlur` on `PlaybackCanvas`.

In the AnimatedBuilder body that already drives the cursor + zoom
Transform:

1. Pull `motion?.velocityPxPerSec` (now part of
   `CursorMotionUpdate`) into a local `cursorVelocity`.
2. Inside `TweenAnimationBuilder.builder` (where the per-frame
   `transform` matrix is in scope), compute
   `screenVelocity = _screenPanTracker.update(transform: transform, position: pos)`.
3. Compute `screenSigma = screenBlurSigma(velocity: screenVelocity, intensity: widget.motionBlur)`.
4. If `screenSigma.dx > 0 || screenSigma.dy > 0`, wrap the
   `composition` in `ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: screenSigma.dx, sigmaY: screenSigma.dy), child: composition)`. Otherwise pass `composition` directly.

The `CursorOverlayPainter` constructor in the Stack now takes
`velocityPxPerSec: cursorVelocity, motionBlurIntensity: widget.motionBlur`.

`screenBlurSigma` is a top-level pure function in
`lib/effects/motion_blur_screen.dart`, called from both the preview
canvas and `frame_compositor` so the two paths can't drift:

```dart
Offset screenBlurSigma({
  required Offset velocity,
  required double intensity,
  double referenceSpeed = 800,
  double maxReach = 10,
}) {
  if (intensity <= 0) return Offset.zero;
  final speedX = velocity.dx.abs();
  final speedY = velocity.dy.abs();
  final fxX = (intensity * speedX / referenceSpeed).clamp(0.0, 1.0);
  final fxY = (intensity * speedY / referenceSpeed).clamp(0.0, 1.0);
  return Offset(fxX * maxReach, fxY * maxReach);
}
```

### Export wiring (`frame_compositor.dart`)

Add `final _screenPanTracker = ScreenPanVelocityTracker()`. In
`compose()`, after `_focalController.update(...)` and after building
the zoom transform, compute `screenVelocity` via the tracker and
`screenSigma` via `screenBlurSigma(...)` from
`lib/effects/motion_blur_screen.dart` — the same function the
preview calls, so the two paths can't drift. Then:

```dart
final hasScreenBlur = screenSigma.dx > 0 || screenSigma.dy > 0;
if (hasScreenBlur) {
  canvas.saveLayer(
    Rect.fromLTWH(0, 0, totalSize.width, totalSize.height),
    Paint()..imageFilter = ui.ImageFilter.blur(
      sigmaX: screenSigma.dx,
      sigmaY: screenSigma.dy,
    ),
  );
}

_paintWallpaper(canvas);
_framePainter.paint(canvas, totalSize);
_paintVideoFrame(canvas, videoImage);
if (motion != null && !projectState.hideCursorOverlay) {
  _paintCursor(canvas, position: position, screenPos: motion.screenPos,
      velocity: motion.velocityPxPerSec, intensity: projectState.motionBlur);
}

if (hasScreenBlur) canvas.restore();
```

`_paintCursor` gains `required Offset velocity, required double intensity`
and forwards them into the `CursorOverlayPainter` constructor.

`projectState.motionBlur` is already on `EditorProjectState` (line 54).

## Data flow

```
slider value ─┬→ playback_canvas: cursor painter intensity + screen ImageFilter sigma
              └→ frame_compositor: cursor painter intensity + saveLayer ImageFilter sigma

cursor recording ─→ CursorMotionController ─→ {screenPos, velocityPxPerSec}
                                                    │
                                                    └→ cursor painter (multi-stamp)

zoom transform   ─→ ScreenPanVelocityTracker ─→ velocityPxPerSec
                                                    │
                                                    └→ ImageFilter.blur sigmas
```

## Edge cases

| Case | Behavior |
| --- | --- |
| `slider == 0` | both surfaces short-circuit to existing path; no `ImageFiltered`, no extra stamps |
| Cursor velocity below 1 px/s | sampler returns `count=1`, single stamp |
| Screen pan velocity below 1 px/s | sigmas round to 0; `ImageFilter` not applied |
| Scrubbing playhead backwards | trackers detect non-monotonic position, return zero velocity |
| Idle paused frame | trackers cache last result keyed by position; no spurious velocity from rebuilds |
| First frame of playback | both trackers return zero; nothing blurs until they have a delta |
| Zoom enter/exit ramp (scale-only, no pan) | screen velocity ≈ 0; ramp stays sharp (intentional) |
| Cursor recording missing (legacy capture) | cursor painter never runs; no behavior change |
| `slider × speed/ref < 0.05` | sampler returns single-stamp (avoid spending `saveLayer` on imperceptible blur) |
| Bbox clipping at canvas edge | stamp bounds always padded by max stamp reach; stamps near edges aren't clipped |

## Testing

### `motion_blur_samples_test.dart` (pure)

- `slider == 0` → `count=1, alphas=[1], stepPx=Offset.zero`.
- Velocity below 1 px/s → single-stamp result regardless of slider.
- Horizontal velocity, slider=1, max speed → `count=8`; stepPx
  purely horizontal and points opposite the velocity.
- Alphas always sum to 1.0 within float tolerance.
- Alphas monotonically increase from oldest tail to head.
- Speed/reference clamped to 1.0 — supersonic cursor doesn't produce
  >maxReach offsets or >maxStamps stamps.
- Diagonal velocity at 45° → stepPx magnitude correct AND step
  direction matches `−v̂` to within 0.01 px (catches sign errors).

### `screen_pan_velocity_tracker_test.dart`

- First call returns `Offset.zero`.
- Two calls with translation Δ=(20,0) over Δt=16ms returns velocity
  ≈ `(1250, 0)` px/s.
- Calling twice with the same `position` returns cached velocity
  without advancing state.
- `reset()` clears state; first call after reset returns zero.
- Backwards-in-time `position` returns `Offset.zero`.

### `cursor_motion_controller_test.dart` additions

- `velocityPxPerSec == Offset.zero` on first call.
- After two updates with smoothed positions advancing 30 px in
  16.6ms, velocity ≈ `(1800, 0)` px/s.
- Scrubbing backwards (position decreasing) returns
  `Offset.zero`.
- `reset()` clears velocity history.

### `cursor_overlay_painter_test.dart`

- `motionBlurIntensity == 0` → exactly one
  `paintCursorWithEffects` call.
- `intensity > 0, velocity > 0` → `count` calls, each preceded
  by `saveLayer` and followed by `restore`.
- Stamps are translated along `−v̂`, head stamp at offset 0.

(Use a Canvas-mocking pattern — record-the-calls test double
similar to existing painter tests.)

### Performance marker test

- A CI-level test that exports a 5-second clip with `motionBlur=1`
  through `frame_compositor` and asserts wall-clock isn't more
  than 1.3× the slider=0 baseline. If it regresses past that, drop
  screen blur sample sigma rather than cursor stamps (cursor is
  the bigger visual win).

## UI copy & rollout

- **Slider subtitle.** Drop the parenthetical
  "(Coming soon — value is captured but not yet rendered.)"
  from `animation_tab.dart:196-198`. Subtitle becomes:
  *"While mouse cursor or screen is moving, cinematic motion blur
  effect will be applied."*
- **"Advanced motion blur settings" collapsible.** Stays as-is
  with its existing "Coming soon" body — per-component tuning
  isn't in v1.
- **Slider reset.** Already wired (`onReset → onMotionBlurChanged(0)`).
  No change.
- **Persistence.** No change. Already serialized.
- **Telemetry.** None for v1. Export estimator's
  `lastRealtimeMultiplier` self-corrects across exports.
- **Feature flag.** None. Slider defaults to 0 so existing projects
  render identically until the user moves it.

## Performance budget

- Slider=0: zero new allocations; one extra integer comparison per
  frame.
- Cursor blur active, count=8: 8 saveLayer/restore pairs per frame
  over a small (~80×80 px) bbox. Negligible on Apple Silicon.
- Screen blur active: one extra `saveLayer` over `totalSize` and
  one `ImageFilter.blur`. GPU-resident on Impeller; expected
  cost <2 ms at 1080p. CI marker test asserts <1.3× export
  baseline; failure path is dropping sigma, not architectural
  change.
