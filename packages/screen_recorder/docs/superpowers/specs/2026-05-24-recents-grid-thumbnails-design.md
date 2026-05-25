# Recents Grid with Styled Thumbnails — Design

**Status:** approved (brainstorm 2026-05-24)
**Topic:** Replace the Recent Recordings list with a thumbnail grid.

## Goal

Turn the Recents screen from a text list into a responsive grid of cards,
each showing a **styled thumbnail** of the recording (as it would export —
wallpaper + window frame + zoom) and a friendly caption (date + duration).

## User-facing behavior

- Recents is a **responsive grid of uniform 16:9 cards**. Columns fill the
  window width and wrap on resize (`SliverGridDelegateWithMaxCrossAxisExtent`,
  max cross-axis extent ~280 px). The recording is letterboxed into the
  16:9 tile (contain, never cropped/stretched).
- **Caption** under each tile:
  - Primary: friendly local datetime — e.g. `May 14, 2026 · 9:33 PM`.
  - Secondary (smaller, dimmed): `0:42 · 2214×1984` (duration · resolution).
- **Click** a card → opens the editor (`PlaybackScreen`), unchanged.
- **Long-press** a card → opens the motion-blur playground
  (`MotionBlurPlaygroundScreen`) — preserve today's hidden affordance.
- **Hover** reveals a small `✕` button in the card's top-right corner →
  removes from history, reusing the existing remove flow/confirmation.
- **Missing file** (path no longer on disk): greyed card with a placeholder
  glyph instead of a thumbnail; `✕` still removes it. Mirrors today's
  missing-row behavior.

## Data model changes

### `meta.json` gains duration (authoritative)

`RecordingMetadata` (`packages/screen_recorder/lib/models/recording_metadata.dart`)
gains `Duration duration` serialized as `durationMs`. Bump `schemaVersion`
1 → 2. Additive and backward compatible:

- `toJson`: add `'durationMs': duration.inMilliseconds`, `'schemaVersion': 2`.
- `fromJson`: `durationMs` is **nullable** — read `Duration(milliseconds: …)`
  when present, else leave duration unknown (sentinel: `Duration.zero` /
  a `bool hasDuration`). Old (v1) sidecars and missing sidecars parse fine.
- Written at **record-stop**: the recorder already tracks elapsed duration
  live (`recording_state.dart` runs a per-second duration timer), so the
  final duration is in hand when the meta sidecar is saved. Thread it into
  the `RecordingMetadata(...)` construction at the existing save site.

### Backfill for existing recordings

When the thumbnail service finds a recording whose meta lacks `durationMs`
(or has no meta sidecar at all), it does a **one-time `ffprobe`** for the
duration and **writes it back** into `meta.json` (upgrading it to v2,
preserving the other fields, defaulting `isPureSource` etc. as the model
already does). So each old recording is probed at most once; thereafter the
caption reads duration straight from meta.

### Thumbnail sidecar

- `recording.mp4.thumb.png` — the styled 16:9 thumbnail, written next to the
  MP4. No separate JSON sidecar.
- **Freshness:** regenerate when `thumb.png` is missing OR `editor.json`'s
  mtime is newer than `thumb.png`'s mtime (an edit to wallpaper/frame/zoom
  changes the styled look). Pure mtime comparison — no stored bookkeeping.

## Thumbnail generation pipeline

New `RecordingThumbnailService`
(`packages/screen_recorder/lib/ui/screens/recents/recording_thumbnail_service.dart`):

```
Future<RecordingThumbnail> thumbFor(RecordingHistoryEntry entry)
  → RecordingThumbnail { File png; Duration duration; }
```

On a cache hit (png exists and is newer than editor.json): return the png
path + duration from meta. On a miss/stale:

1. Resolve duration: read `meta.json` `durationMs`; if absent, `ffprobe` the
   mp4 and backfill meta (above).
2. Pick the frame timestamp: `t = clamp(0.1 × duration, 1s, duration − 1 frame)`
   — a little in, to skip black intro frames. Pure helper, unit-tested.
3. `ffmpeg` decodes that single frame to BGRA (mirror `FfmpegDecoder`'s
   `Process.start('ffmpeg', …)` convention; `-ss t -frames:v 1`).
4. Load the recording's sidecars: `editor.json` → `EditorProjectState`,
   `cursor.json` → `CursorRecording`, `meta.json` → `RecordingMetadata`
   (reuse existing loaders — `EditorProjectStore`, `RecordingMetadata`).
5. Run `FrameCompositor.compose(videoFrameBgra: frame, position: t)` for that
   one frame → RGBA bytes → encode PNG → write `recording.mp4.thumb.png`.
6. Return the png + duration.

**Concurrency:** an async work queue with a small concurrency limit (2–3)
so opening the grid doesn't spawn 20 ffmpeg processes at once. Cards show a
shimmer placeholder until their thumb resolves. A tiny in-memory map caches
the resolved `RecordingThumbnail` per `videoPath` for the session (mirrors
`source_picker/thumbnail_cache.dart`).

**Heavy-work note:** `FrameCompositor` is the export path; one frame is
cheap-ish but runs on the platform thread. If the grid janks, the existing
`isolate_frame_compositor.dart` is the upgrade path — **out of scope for v1**;
the concurrency cap is the v1 mitigation.

**Failure handling:** any step failing (corrupt mp4, missing editor.json,
ffmpeg error) → log and return a neutral placeholder card; never throw into
the grid. Missing **file** (mp4 gone) is detected up front → greyed card.

## UI structure (files)

- **Modify** `packages/screen_recorder/lib/ui/screens/recents_screen.dart`
  — replace the `ListView` with a `GridView` using
  `SliverGridDelegateWithMaxCrossAxisExtent` (maxCrossAxisExtent ~280,
  childAspectRatio tuned for 16:9 tile + 2-line caption, spacing ~16).
  Keep the existing `RecordingHistoryStore` load/refresh/remove logic and the
  `_exists` on-disk check.
- **Create** `packages/screen_recorder/lib/ui/screens/recents/recording_card.dart`
  — one card widget. Inputs: the entry, `exists` bool, `onOpen`,
  `onOpenPlayground`, `onRemove`, and the `RecordingThumbnailService`. Renders
  the three visual states (loading shimmer / ready image / missing-or-failed
  placeholder), the caption, and the hover-`✕`. No store/IO logic itself.
- **Create** `packages/screen_recorder/lib/ui/screens/recents/recording_thumbnail_service.dart`
  — the service above + an in-memory `RecordingThumbnail` cache.

## Component boundaries

- `RecordingThumbnailService` — owns generation/caching/probe/backfill. Pure
  data in (entry) → data out (png + duration). No widgets. Independently
  testable (cache validity, timestamp clamp) with the ffmpeg/compositor calls
  behind a thin seam so tests don't shell out.
- `RecordingCard` — pure presentation: given a future/stream of thumbnail
  state, render it. No knowledge of the store or ffmpeg.
- `RecentsScreen` — orchestration: load history, lay out the grid, wire
  card callbacks to navigation + remove. Unchanged store interaction.

## States

| State | Card appearance |
|---|---|
| Generating | shimmer/placeholder in the 16:9 area, caption shown from history (date + resolution; duration once known) |
| Ready | styled PNG, full caption (date + duration + resolution) |
| Missing file | greyed, placeholder glyph, caption dimmed, `✕` works |
| Generation failed | neutral placeholder (distinct from missing), caption from history, logged |

## Testing

- **Unit (`RecordingThumbnailService` seam):**
  - cache validity: png newer than editor.json → hit; png missing or older →
    regenerate. (Use temp files + mtimes; mock the generate seam.)
  - frame-timestamp clamp: pure function `thumbTimestamp(duration)` →
    boundaries (very short clip, normal clip, ~0 duration).
  - meta backfill: when meta lacks `durationMs`, after resolve the meta file
    has `durationMs` + `schemaVersion: 2` (probe seam mocked).
- **`RecordingMetadata`:** round-trip with `durationMs`; v1 (no durationMs)
  parses with duration unknown; v1→write produces v2 JSON.
- **Widget (`RecordingCard`) with a fake service:** loading, ready (renders an
  `Image`), and missing-file states; hover reveals `✕`; tap fires `onOpen`;
  long-press fires `onOpenPlayground`. No ffmpeg in tests.
- **`RecentsScreen` smoke:** grid renders N cards from a stubbed store; remove
  callback drops a card.

## Out of scope (v1)

User-renaming recordings; multi-select; hover scrubbing-preview; isolate
offload of thumbnail compositing; thumbnail pre-generation at record/export
time (lazy-on-view only).
