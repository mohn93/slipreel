# Slice speed presets up to 24× — Design

**Date:** 2026-06-14
**Status:** Approved (brainstorming) → ready for implementation plan

## Goal

Let editors speed up a timeline slice far beyond the current 4× ceiling — up to
**24×** — for timelapse-style sections, while keeping fine control near 1× and
avoiding unusable chipmunk audio at high speeds.

## Background (current state)

- `ClipSlice.playbackSpeed` is a stored `double` (default `1.0`).
- `EditorProjectController.setSliceSpeed` clamps to **`0.25..4.0`**.
- Slice editor (`slice_editor.dart`) shows preset chips `[0.5, 1.0, 1.5, 2.0]`
  plus a linear "Fine-tune" `InspectorSlider` with `min: 0.25, max: 4.0`.
- Export already handles arbitrary speeds:
  - Video: `setptsForSpeed(speed) => 'setpts=PTS/$speed'` (any factor).
  - Audio: `atempoChain(speed)` chains `atempo` (each factor in `[0.5, 2.0]`)
    so >2× already works.
  - Output duration: `Σ effectiveLength / playbackSpeed`
    (`_slicedOutputSeconds`, also used by the progress denominator).
- Preview applies per-slice speed via `VideoPlayerController.setPlaybackSpeed`.

So the engine is already speed-agnostic. This feature is **UX + the clamp
ceiling + an audio-at-high-speed policy**.

## Non-goals

- No change to the global recording-audio volume control (that is the separate
  m7 `setAll*` path).
- No per-slice "keep audio when sped up" toggle (rejected in brainstorming in
  favour of a fixed threshold).
- No JSON/persistence migration (existing `playbackSpeed` values are already in
  the new range).

## Design

### 1. Clamp ceiling

`EditorProjectController.setSliceSpeed`: clamp `0.25..4.0` → **`0.25..24.0`**.
Lower bound unchanged. The `setX(currentX)` no-op invariant
(`if (clamped == s.playbackSpeed) return;`) stays.

### 2. Speed control UX (`slice_editor.dart`)

**Preset chips** (extended): `0.5× · 1× · 1.5× · 2× · 4× · 8× · 16× · 24×`.
Rendered in the existing `Wrap`; chip selected when
`(clip.playbackSpeed - s).abs() < 0.001`.

**Logarithmic fine-tune slider.** The `InspectorSlider` operates on a normalized
position `t ∈ [0, 1]` instead of raw speed, via a pure helper:

```
class SpeedScale {
  static const double min = 0.25;
  static const double max = 24.0;
  static const List<double> detents = [0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 8.0, 16.0, 24.0];

  // speed = min * (max/min)^t
  static double speedFromPos(double t);   // clamps t to [0,1]
  static double posFromSpeed(double s);   // ln(s/min)/ln(max/min), clamps s to [min,max]
  // Snap a position to the nearest detent when within `posTolerance` (~0.02)
  // in normalized space; otherwise return the raw speed.
  static double snap(double speed, {double posTolerance = 0.02});
}
```

- Slider `value: SpeedScale.posFromSpeed(clip.playbackSpeed)`, `min: 0`,
  `max: 1`.
- `onChanged: (t) => setSliceSpeed(SpeedScale.snap(SpeedScale.speedFromPos(t)))`.
- `onReset` → `1.0` (unchanged).
- Subtitle keeps `Final speed: ${(playbackSpeed*100).round()}%`.

Snapping to detents (including exactly `1.0×`) guarantees common values are
reachable despite the log mapping. `SpeedScale` is fully unit-tested
(round-trip `posFromSpeed`∘`speedFromPos`, endpoints, monotonicity, snap
behaviour inside/outside tolerance).

### 3. Audio auto-mute above threshold (derived, non-destructive)

Constant `kSpeedAudioMuteThreshold = 4.0` (defined in `clip_slice.dart`, next to
`ClipSlice`, so both the engine export path and the UI import it from one
place). A slice is **speed-muted** when
`playbackSpeed > kSpeedAudioMuteThreshold`. This is computed from speed and does
**not** mutate `micMuted`/`systemMuted` — lowering the speed back to ≤4× restores
audio. Add a derived getter, e.g. `ClipSlice.audioSilencedBySpeed =>
playbackSpeed > kSpeedAudioMuteThreshold` (pure, unit-tested).

**Export** (`n_slice_filter_graph.dart` filter-graph builder): for a speed-muted
slice the audio branch is **silenced by forcing `volume=0` while KEEPING the
`atempo` chain** (rather than substituting a separately-computed silence). This
is the existing user-mute mechanism, extended: keeping `atempo` means the silent
branch retains the slice's exact sped-up duration, so the per-track `concat`
stays frame-aligned with the video `concat` for any mix of muted/unmuted slices.
Effectively `muted || audioSilencedBySpeed` drives the `volume=0` decision per
track.

> Implementation note (2026-06-14): an earlier draft of this section said
> "emit silence *instead of* the atempoChain." The shipped approach keeps
> `atempo` + `volume=0` because it guarantees alignment without a hand-computed
> silence duration. Do not "fix" the code back to dropping `atempo`.

**Preview** (`playback_screen.dart`): when the slice under the playhead is
speed-muted, set the player volume to 0 (alongside the existing per-slice
`setPlaybackSpeed`). Restore volume when crossing back under the threshold.

**Slice editor:** when the current slice is speed-muted, grey out the Audio
section's gain rows and show a one-line note "Muted above 4×" so the state is
explained rather than silently ignored.

### 4. Preview fidelity

At very high speeds AVPlayer may stutter or drop frames; preview is approximate
and the exact result is the export. No special handling beyond the volume mute
above. (Document this; do not try to make preview pixel-exact at 24×.)

## Testing

- **`SpeedScale`** (engine unit): round-trip, endpoints (0→0.25×, 1→24×),
  monotonic increasing, `1.0×` maps to a stable position, snap pulls to nearest
  detent within tolerance and leaves off-detent values alone.
- **Controller** (engine unit): `setSliceSpeed` clamps to `0.25..24.0`
  (e.g. `100 → 24`, `-1 → 0.25`); `setX(currentX)` still a no-op.
- **`audioSilencedBySpeed`** (engine unit): false at ≤4×, true at >4×.
- **Export** (engine unit): a >4× slice's audio branch is silence, not
  `atempo`; output duration unchanged by the mute; existing multi-slice export
  tests still pass.
- **Slice editor** (app widget): new chips render and select; the fine-tune
  slider position reflects/changes speed via the log mapping; Audio section is
  disabled with the note when speed >4×.

## Affected files (anticipated)

- `packages/slipreel_engine/lib/state/editor_project_controller.dart` — clamp.
- `packages/slipreel_engine/lib/state/clip_slice.dart` — threshold constant +
  `audioSilencedBySpeed` getter.
- `packages/slipreel_engine/lib/editor/speed_scale.dart` — new `SpeedScale`.
- `packages/slipreel_engine/lib/export/export_pipeline.dart` (+
  `ffmpeg_filters.dart`) — emit silence for speed-muted slices.
- `packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart`
  — chips, log slider, disabled-audio affordance.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — preview
  volume mute above threshold.
- Tests alongside each.
