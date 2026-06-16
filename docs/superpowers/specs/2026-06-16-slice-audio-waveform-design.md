# Slice Audio Waveform — Design

**Date:** 2026-06-16
**Status:** Approved (brainstorming complete; ready for implementation plan)

## Summary

Render a subtle audio waveform "chart" inside each main clip slice in the
bottom timeline bar, so a slice visually indicates the audio it contains.
The waveform is a bottom-anchored, smoothed area chart with a low-opacity
gradient fill and a thin bright top stroke. It only appears when the
recording actually has audio.

## Goals

- Each main clip slice shows a waveform representing its audio content.
- The curve maps to the slice's real source time range, so trim, cut, split,
  and speed changes render the correct portion automatically.
- The effect is quiet/subtle — an accent behind the slice label, not a focal
  element.
- No perceptible editing or playback performance cost.

## Non-goals

- Per-stream (mic vs system) separate curves. We show one combined-mix curve.
- Gain-reactive height. Volume/gain changes do not alter the curve shape.
- Waveform on non-clip lanes (zoom lane, camera lane, keystroke lane).
- A full audio-scrubbing/zoom waveform editor.

## Locked design decisions

These were settled during brainstorming:

1. **Visual style:** Bottom-anchored area chart (keeps the top of the slice
   clear for the label). Smoothed Catmull-Rom → bézier spline with rounded
   peaks. Low opacity: gradient fill ~30% at the bottom edge fading to
   transparent ~80% up, plus a thin bright top stroke at ~45% opacity.
2. **Audio source:** Combined mix of whatever audio streams exist (mic +
   system), summed to a single mono signal.
3. **Settings reactivity:** Mute dims the whole curve to near-invisible; gain
   does **not** change height. (Also dim when the slice is silenced by speed,
   `audioSilencedBySpeed`, i.e. >4×.)
4. **Data source / timing:** ffmpeg extraction on editor load, downsampled to
   a peak array, cached to a sidecar file. Structured so extraction can later
   also be triggered at record-stop as a pure optimization, with no other
   changes.

## Architecture

Four new units plus one integration point. New code lives in
`packages/screen_recorder` (UI) and `slipreel_engine` (model/service/state),
following existing package boundaries.

### 1. `WaveformPeaks` (model)

Immutable value object in `slipreel_engine`:

- `int bucketsPerSecond` — fixed peak rate (target ~100 buckets/sec).
- `List<double> peaks` — normalized 0.0–1.0 amplitude across the **whole
  source timeline** of the recording.
- `Duration sourceDuration`.
- `==` / `hashCode` (consistent with the project's state-equality convention).
- `List<double> slice(Duration sourceStart, Duration sourceEnd)` — pure helper
  returning the sub-range of peaks for a given slice's source span.

### 2. `WaveformExtractor` (service)

- Runs a single ffmpeg pass over the recording: mixes existing audio streams
  to mono ~8 kHz `s16le` and pipes raw PCM to Dart.
  - Two audio streams → `amix=inputs=2`.
  - One audio stream → straight `-map`.
  - Zero audio streams → returns `null` (no waveform).
- Reduces the PCM stream to a fixed-rate peak array via a **separate pure
  function** (`reducePcmToPeaks`) that is unit-testable with synthetic PCM.
- Normalizes peaks to the recording's global loudest point.
- Returns `WaveformPeaks?`.

### 3. Sidecar cache

- File: `<recording>.waveform.json`, versioned (format version + source path).
- `WaveformExtractor` writes it after a successful extraction; reads
  short-circuit re-extraction.
- A format-version bump ignores stale sidecars and re-extracts.
- Mirrors the app's existing sidecar pattern (`.camera.json`, checkpoint
  NDJSON).

### 4. `waveformProvider`

- Riverpod provider keyed by `videoPath`.
- On read: load sidecar if present; otherwise start extraction async, write the
  sidecar, then update.
- Exposes `AsyncValue<WaveformPeaks?>` so the UI fades the curve in when ready
  and renders nothing meanwhile.

### 5. Integration: `SliceBar` + `WaveformPainter`

- `SliceBar` gains an optional `CustomPaint` layer (`WaveformPainter`) painted
  **behind** the existing label, only when peaks exist for the recording.
- `WaveformPainter` receives the slice's peak sub-range, the dim flag, and the
  render width.

## Data flow

1. Editor opens → `waveformProvider(videoPath)` is read.
2. Sidecar hit → loads instantly. Miss → ffmpeg extraction runs async (one pass
   for the whole recording), writes the sidecar, emits result.
3. Provider emits `WaveformPeaks` → `ClipLane` rebuilds → each `SliceBar` fades
   its curve in (~200 ms).
4. Each `SliceBar` calls `peaks.slice(sourceStart, sourceEnd)` for its own
   source range and hands the result to `WaveformPainter`.

## Rendering details

- **Mapping:** peaks are sampled by **source range** and stretched across the
  slice's **rendered (edited) pixel width**. A 2× slice shows its source audio
  compressed into a narrower bar — trim/cut/split/speed all render correctly
  with no extra logic.
- **Shape:** bottom-anchored area; smooth spline; rounded peaks; gradient fill
  (~30% → transparent) + thin bright top stroke (~45%).
- **Dim rule:** if the slice's mix is effectively silent — all present streams
  muted, or `audioSilencedBySpeed` is active — the whole curve drops to a
  near-invisible opacity. Gain does not change height.
- **Normalization:** once to the recording's global max, so quiet recordings
  still read and levels are consistent across all slices of the same recording.
- **Repaint discipline:** `WaveformPainter.shouldRepaint` returns true only
  when the peak sub-range, width, or dim state changes — it must not repaint
  during 60 Hz playback (consistent with the playback-perf baseline).

## Edge cases

- **No audio** → provider emits `null`; no curve; slice renders as today.
- **Extraction in flight** → no curve yet; fades in when ready; no spinner, no
  layout shift (overlay, not a layout child).
- **Extraction fails / ffmpeg error** → log, emit `null`, slice renders as
  today. Never blocks the editor.
- **Very narrow slices** → below a small pixel-width threshold, skip painting
  to avoid visual noise.
- **Stale sidecar** → format-version mismatch → re-extract.
- **Recovered / fragmented recording** → waits for a normal `videoPath`; no
  special path.

## Testing

- **`reducePcmToPeaks`** (pure) — synthetic PCM (silence, full-scale, ramps) →
  assert bucket counts and normalized values.
- **`WaveformPeaks.slice()`** (pure) — full range, trimmed, cut, sped-up slices
  → assert correct bucket sub-range.
- **Sidecar round-trip** — serialize → deserialize → equality.
- **`==` / `hashCode`** on `WaveformPeaks`.
- **Extractor ffmpeg pass** — one light integration test against a short
  fixture clip with known audio, plus a no-audio fixture → `null`.
- **Painter** — optional golden test (non-blocking).
- **Manual verification** — open a recording with mic + system audio; confirm
  the curve appears under the label, tracks where sound actually is, compresses
  on sped-up slices, and dims on muted / >4× slices.

## Future work (out of scope)

- Trigger extraction at record-stop time so the sidecar is always ready when
  the editor opens (pure optimization on top of this design).
- Optional per-stream or gain-reactive rendering.
