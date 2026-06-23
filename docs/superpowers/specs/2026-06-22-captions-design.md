# Captions — auto STT + manual editing + burn-in render

- **Date:** 2026-06-22
- **Issue:** [#14 — Captions: implement auto speech-to-text + manual editing + render](https://github.com/mohn93/slipreel/issues/14)
- **Status:** Design approved; ready for implementation planning.

## Goal

Replace the placeholder `CaptionsTab` with a working captions feature:

1. **Auto-generate** captions from the recording's audio using on-device speech-to-text.
2. **Edit** the generated segments (text, timing, split/merge) in the inspector.
3. **Render** the captions as a timed overlay in both the editor preview and the
   exported video (burn-in).

## Approved decisions

| Decision | Choice | Rationale |
|---|---|---|
| STT engine | **Bundled whisper.cpp** (subprocess) | Offline, private, no API key/cost; matches the existing "bundled binary invoked as a subprocess" pattern (ffmpeg) and the distribute-direct strategy. |
| Model + delivery | **Download `small` on first use** | Lean installer; best accuracy for technical terms. Needs a download/progress/cache/verify flow. Multilingual `small` (auto language-detect) so non-English works. |
| Audio source | **Per-project selector** at generate-time | Recordings can have mic and/or system tracks; the user picks mic / system / mixed. Selector only offers tracks that exist. |
| Edit UX (v1) | **Inspector list editor only** | Full editing loop (text, timing, split/merge) without touching the timeline lane stack. A timeline caption lane is a follow-up. |
| Export (v1) | **Burn-in only** | Render into the exported pixels. `.srt`/`.vtt` sidecar export is a trivial fast-follow once segments exist. |

## Architecture

```
[Recording .mov]
  → CaptionAudioExtractor   (ffmpeg → 16 kHz mono pcm_s16le WAV, per chosen source)
  → CaptionTranscriber      (whisper-cli subprocess → JSON → List<CaptionSegment>)
  → CaptionTrack            (persisted in <video>.editor.json, schema v10)
  → CaptionRenderer         (one painter; drawn in BOTH preview + export)
```

Each stage mirrors an existing pattern in the codebase:

- ffmpeg audio extraction → `buildWaveformPcmArgs` /
  `WaveformExtractor` (`packages/slipreel_engine/lib/audio/waveform_extractor.dart`).
- subprocess-via-resolver → `Ffmpeg` / `FfmpegResolver`
  (`packages/slipreel_engine/lib/export/ffmpeg_resolver.dart`).
- sidecar persistence → `EditorProjectState` / `EditorProjectStore`
  (`<video>.editor.json`).
- canvas-fixed overlay → camera bubble in `FrameCompositor.compose()`
  (`packages/slipreel_engine/lib/export/frame_compositor.dart`).

## Components

Each component has one purpose, a narrow interface, and explicit dependencies.

### 1. Whisper binary resolution — `WhisperResolver` / `Whisper`

- **Purpose:** Locate the `whisper-cli` binary for the packaged app.
- **Interface:** `Whisper.resolve() → String` (absolute path); throws
  `WhisperNotFoundException(searchedLocations)` if missing. Process-wide facade
  with an overridable `resolver` (test seam), exactly like `Ffmpeg`.
- **Resolution order:** `bundledPath` hook (null today) → well-known paths
  (`/opt/homebrew/bin/whisper-cli`, `/usr/local/bin/whisper-cli`, plus the
  legacy `whisper-cpp` / `main` names) → `PATH`.
- **Dependencies:** `dart:io`.
- **Shipping note (honest):** Actually bundling + signing the binary inside the
  `.app` is the same still-pending chore as ffmpeg (which today also resolves via
  Homebrew, not a bundled binary). In dev/v1 it resolves from Homebrew/PATH;
  shipping the bundled binary rides along with the distribution work (issue #1).
  The resolver's `bundledPath` hook makes that a one-line wire-up later. If the
  binary is not found, the Captions tab surfaces a clear "install whisper-cli"
  affordance instead of failing silently.

### 2. Model management — `WhisperModelStore`

- **Purpose:** Ensure `ggml-small.bin` is present on disk; download + cache on
  first use.
- **Interface:**
  - `Future<String> ensureModel({void Function(double progress)? onProgress})`
    → absolute path to the model file. Returns immediately if cached & valid.
  - Emits download progress 0..1.
- **Behavior:** Stores under the app-support dir
  (`<appSupport>/whisper/ggml-small.bin`). On miss: download from the pinned
  HuggingFace URL to a `.part` file, verify SHA-256 against a pinned digest,
  atomic-rename into place. A failed/corrupt download is deleted and retried on
  next attempt (never leaves a half file in the cache path).
- **Dependencies:** `http`/`dart:io` for download, `crypto` for SHA-256,
  `path_provider` for the app-support dir.
- **Constants:** model URL + SHA-256 pinned in one place; model = multilingual
  `small`.

### 3. Audio extraction — `CaptionAudioExtractor`

- **Purpose:** Produce a 16 kHz mono WAV from the recording for the chosen
  source.
- **Interface:** `Future<String> extract(String videoPath, CaptionAudioSource
  source) → temp WAV path`. Pure arg-builder `buildCaptionAudioArgs(videoPath,
  source, streamCount)` is unit-tested in isolation (mirrors
  `buildWaveformPcmArgs`).
- **ffmpeg mapping:**
  - mic → `-map 0:a:0`
  - system → `-map 0:a:1`
  - mixed → `-filter_complex [0:a:0][0:a:1]amix=inputs=2:duration=longest[aout] -map [aout]`
  - then `-vn -ac 1 -ar 16000 -c:a pcm_s16le -f wav <out>`
- **Source availability:** `ffmpegProbe` reports the audio-stream count; the
  selector only offers sources that exist (single-track recordings skip the
  selector and use the one track).
- **Dependencies:** `Ffmpeg.resolve()`, `ffmpegProbe`, temp dir.

### 4. Transcription — `CaptionTranscriber`

- **Purpose:** Run whisper-cli on the WAV and parse its output into segments.
- **Interface:** `Future<List<CaptionSegment>> transcribe({required String
  audioPath, required String modelPath, String language = 'auto', void
  Function(double progress)? onProgress})`.
- **Invocation:** `whisper-cli -m <model> -f <audio> -oj -of <outBase> -l <lang>
  [--no-prints] [--print-progress]`. `-oj` writes `<outBase>.json`; progress is
  parsed from stderr when available (best-effort; not required for correctness).
- **Parsing:** Read the JSON `transcription` array → `{ offsets:{from,to} (ms),
  text }`. Convert ms→micros, trim whitespace, drop empty segments, assign ids.
  Parser is defensive across whisper.cpp JSON shape variations and unit-tested
  against a captured fixture.
- **Dependencies:** `Whisper.resolve()`, `dart:io` (Process), `dart:convert`.

### 5. Orchestration — `CaptionGenerationController` (Riverpod)

- **Purpose:** Drive the end-to-end generation and expose status to the UI.
- **State:** `CaptionGenerationStatus` =
  `idle | downloadingModel(progress) | extracting | transcribing(progress) |
  done | error(message)`.
- **Flow:** `generate(videoPath, source)` →
  `WhisperModelStore.ensureModel` → `CaptionAudioExtractor.extract` →
  `CaptionTranscriber.transcribe` → write segments into the editor via
  `EditorProjectController` (replaces the current caption track's segments,
  preserves style). Cleans up temp WAV. Errors map to `error(message)` and never
  crash the editor.
- **Dependencies:** the three components above + `EditorProjectController`.

### 6. Data model

- `CaptionSegment { String id; int startMicros; int endMicros; String text; }`
  — value type with `toJson`/`fromJson`, `copyWith`, `==`/`hashCode`.
- `CaptionTrack { List<CaptionSegment> segments; CaptionAudioSource source; }`
  — lives on `Timeline.captionTracks` (the scaffolding comment in
  `timeline.dart` already reserves this; matches `zoomTracks`/`cameraTracks`).
  Convenience accessor `EditorProjectState.captions` → active track's segments
  (mirrors `zoomRegions` / `cameraRegions`).
- `CaptionStyle { bool enabled; CaptionPosition position; double fontScale;
  Color textColor; CaptionBackground background; }` where
  `CaptionPosition = { top, bottom }` and `CaptionBackground = { box, outline,
  none }`. Lives on `EditorProjectState.captionStyle` (a per-project look, like
  `keystrokeOverlay` / `cameraSettings`).
- `CaptionAudioSource = { mic, system, mixed }`.

**Model placement rationale:** track-data on `Timeline`, look-settings on
`EditorProjectState` — the exact split used by the camera layer. Rejected a flat
field on state as short-term debt that the timeline scaffolding already tells us
to avoid.

### 7. Persistence (schema v9 → v10)

- Bump `EditorProjectState.currentSchemaVersion` 9 → 10.
- Add an **additive no-op migration** `v9→v10` (identical shape to the v8→v9
  camera step): `(json, _) => {...json, 'schemaVersion': 10}`.
- `Timeline.fromJson` fills an empty `captionTracks` list when the key is absent;
  `EditorProjectState.fromJson` fills a default `CaptionStyle` when absent — so
  old projects load cleanly.
- Extend `Timeline` and `EditorProjectState` `toJson`/`fromJson`/`copyWith`/
  `==`/`hashCode` for the new fields.
- On-disk location unchanged: `<videoPath>.editor.json`, written by
  `EditorProjectStore` (debounced save already in place).

### 8. Rendering — `CaptionRenderer`

- **Purpose:** One pure painter so preview and export are frame-for-frame
  identical.
- **Interface:** `CaptionRenderer.paint(Canvas canvas, Size canvasSize, Duration
  t, List<CaptionSegment> segments, CaptionStyle style)`.
- **Behavior:** Selects the active segment at `t` (binary search by time), wraps
  text to a max fraction of canvas width, positions bottom-center or top-center
  with safe-area padding, draws background (rounded box / text outline / none),
  then the text. Font size derives from `fontScale × canvas height` so it scales
  with output resolution. **Canvas-fixed** — not zoom-transformed, so captions
  stay put during zoom.
- **Export wiring:** call in `FrameCompositor.compose()` immediately after
  `paintCamera(composeCanvas)` (and the analogous spot in the device-frame
  path), using `totalSize` and the frame `position`.
- **Preview wiring:** a thin `CustomPaint` in the PlaybackCanvas stack (full
  `effTotalSize`) delegating to the same renderer.
- **Dependencies:** `dart:ui`, the model + style types.

### 9. UI — Captions inspector tab

- Flip `InspectorTab.captions` to `isEnabled: true`.
- Replace `captions_tab.dart` placeholder with:
  - **Audio source selector** (only sources that exist) + **Generate** button.
  - **Progress / status** bound to `CaptionGenerationController`: downloading
    model (X%) → extracting → transcribing → done / error, with a retry on
    error and a clear "install whisper-cli" / "download model" affordance when
    prerequisites are missing.
  - **Segment list editor:** per row — inline editable text, start/end fields,
    **split / merge / delete**, click-to-seek (seeks the preview to the
    segment). Edits go through `EditorProjectController`.
  - **Style controls:** enabled toggle, position (top/bottom), font size, text
    color, background style.
- Uses the existing inspector/theme widgets (`AppPalette`, inspector section
  scaffolding) for consistency.

## Error handling

- **Missing binary** → `WhisperNotFoundException`; tab shows install guidance,
  Generate disabled.
- **Model download failure** → status `error`; partial file deleted; retry
  available. Checksum mismatch treated as failure.
- **No audio in recording** → Generate disabled with an explanatory note
  (probe reports 0 streams).
- **ffmpeg / whisper non-zero exit** → status `error(message)` with stderr tail;
  editor state untouched.
- **Corrupt/older sidecar** → loads via the migration chain; absent caption keys
  fill defaults (never discards the rest of the project).

## Testing

Respecting the CI split (engine-portable unit tests run on the Linux job;
host-specific goldens are `@TestOn('mac-os')`):

- **Portable unit tests** (`slipreel_engine`):
  - `CaptionSegment` / `CaptionTrack` / `CaptionStyle` JSON round-trip.
  - Schema v9→v10 migration (and a v2/older project still loads).
  - `buildCaptionAudioArgs` for mic / system / mixed.
  - whisper-JSON parser against a captured fixture (incl. ms→micros, empty-drop).
  - Active-segment-at-T selection (boundaries, gaps, overlaps).
  - `CaptionRenderer` layout math (wrap width, position offsets) where testable
    without a real canvas.
  - `CaptionGenerationController` status reducer with a faked transcriber/store.
- **Host-only golden** (`@TestOn('mac-os')`): a rendered caption frame
  (box + outline variants).

## Out of scope for v1 (explicit follow-ups)

- Timeline caption **lane** for visual drag-re-timing.
- `.srt` / `.vtt` sidecar export.
- Actually **bundling + signing** the whisper binary in the `.app` (rides issue
  #1 distribution; dev uses Homebrew/PATH meanwhile).
- Per-word/karaoke highlighting.
- Translation / multi-language UI (v1 is auto language-detect).

## Risks / open items

- **whisper.cpp JSON shape** varies across versions; the parser must be
  defensive (mitigated by a captured fixture + tolerant parsing).
- **Model size (~466 MB) first-run download** is large; needs clear progress and
  resumability is a possible later refinement (v1: clean retry on failure).
- **Binary availability in dev**: contributors need `whisper-cli` on PATH until
  the bundle lands; documented in the tab affordance and the engine README.
