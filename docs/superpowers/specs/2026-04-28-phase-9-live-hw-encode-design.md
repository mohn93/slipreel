# Phase 9 Design: Live HW Encode + Perf Instrumentation

**Status:** Approved (brainstorming complete, awaiting plan)
**Date:** 2026-04-28
**Scope:** macOS first; Windows/Linux stay on legacy spool path until a follow-up phase.

## Goal

Hit Phase 9's three perf targets:

- **Recording**: 60 FPS at <10% CPU, <500 MB memory for a 30-minute recording, <1% dropped frames.
- **Export**: 1080p30 export at ≥1.0× real-time (stretch goal: ≥5×) with all default effects applied.
- **Visibility**: each recording and each export emits a one-line perf summary so we can verify targets per session and catch regressions.

We achieve this by moving from a per-frame BGRA-spool architecture to a live-encoded MP4 written directly by the OS, and by switching the export encoder from `libx264` to `h264_videotoolbox`.

## Non-goals

- Windows/Linux live HW encode (deferred — those platforms keep the existing spool-based path).
- 4K 60fps optimization beyond what falls out of the architecture change.
- Buffer pooling, GPU-shaded effects, native AVAssetReader-based export — all explicitly deferred. Listed only if instrumentation later shows they're needed.
- Per-frame timing traces, debug HUD overlays. Minimal-viable instrumentation only.

## Architecture overview

### Today's data flow

```
Capture (CMSampleBuffer)
  → native Data copy (synchronous, on capture thread)
  → Dart Event Channel
  → cursor_renderer composites cursor in-place
  → Uint8List per frame to isolate
  → write frame_NNNNNN.bgra (raw)         [recording]
  → audio_NNNNNN.pcm (raw)
─────────── stop pressed ──────────────
  → FFmpeg libx264 reads .bgra glob       [finalize]
  → FFmpeg muxes with concatenated PCM
  → final.mp4
```

Hot-path costs we're eliminating:

- **Native pixel-buffer copy**: full BGRA frame copied from `CVPixelBuffer` to a `Data` object every frame (~100-200 MB/s at 1080p30, blocks the capture thread).
- **Cursor renderer in the recording hot path**: 4× full-frame pixel scan per frame for BGRA↔RGBA conversions plus a `Canvas` paint, all before the user has even chosen their effects.
- **Raw `.bgra` disk spool**: ~1.4 Gbps of disk write at 1080p60 uncompressed.
- **PCM concat + FFmpeg finalize**: a multi-second pause after stop before the user has a playable file.
- **`libx264` software encoder** at export: 5-10× slower than the HW alternative.

### New data flow

```
Capture (CMSampleBuffer)
  → VTCompressionSession (HW H.264, on capture thread)
  → AVAssetWriter (video + audio sample writers)
  → recording.mp4 (already a real MP4 with audio when stop is pressed)

Cursor positions → CursorRecording (sidecar JSON, unchanged)

─────────── user clicks Export ──────────────

  → FFmpeg decodes recording.mp4 → BGRA frames on stdout
  → existing isolate: cursor_renderer + background/zoom/frame effects
  → FFmpeg h264_videotoolbox re-encodes              [export, HW]
  → audio passed through unchanged (-c:a copy)
  → export.mp4
```

### What changes

- `screen_recorder_macos` plugin gains a **`LiveRecordingWriter`** component (VTCompressionSession + AVAssetWriter glue).
- The existing `frameStream` and audio Event Channels are no longer used during normal macOS recording — the native side writes the file itself and reports only progress (frame count, bytes written) and a perf-stats blob to Dart. The channels remain in the platform interface for Windows/Linux's legacy spool path.
- `video_encoder.dart` shrinks to a thin façade over the platform's live-writer API.
- `cursor_renderer.dart` and `effects/*` move out of the recording hot path. They run only at export and as preview overlays.
- The platform-interface package gains a `LiveRecordingWriter` interface; Windows/Linux get default implementations that throw `UnsupportedError` and continue using the legacy spool path.

### What does NOT change

- Higher-level platform-interface API (`startRecording`, `stopRecording`, `pauseRecording`).
- `CursorRecording` model and the cursor event channel.
- The export pipeline's compositor isolate, the effect implementations, the editor's zoom/trim/timeline UI, undo/redo.
- Audio capture in `AudioCaptureManager.swift` — still tapping `AVAudioEngine`, just feeding samples into AVAssetWriter instead of `.pcm` files.

## Recording pipeline (live HW encode)

### Native components in `screen_recorder_macos`

- **`LiveRecordingWriter.swift`** *(new)* — owns an `AVAssetWriter` configured for `.mov`/`.mp4` output, with two `AVAssetWriterInput`s:
  - **Video input**: `AVVideoCodecType.h264`, expects compressed sample buffers from VTCompressionSession.
  - **Audio input**: AAC encoding, expects raw PCM sample buffers from `AVAudioEngine`.
- **`VideoToolboxEncoder.swift`** *(existing skeleton — promoted from placeholder to active code)* — receives `CVPixelBuffer` from the capture stream, hands it to `VTCompressionSession`, gets back compressed `CMSampleBuffer`s, forwards them to `LiveRecordingWriter`'s video input.
- **`ScreenCaptureManager.swift`** *(modified)* — capture stream's `didOutputSampleBuffer` callback no longer reaches into pixel data. It just forwards the `CMSampleBuffer` to `VideoToolboxEncoder`. The synchronous `CVPixelBufferLockBaseAddress` + `Data(bytes:count:)` copy on the capture thread is **gone**.
- **`AudioCaptureManager.swift`** *(modified)* — instead of converting float→Int16 and emitting PCM via Event Channel, forwards `CMSampleBuffer`s directly to `LiveRecordingWriter`'s audio input. AVAssetWriter handles AAC encoding.

### VTCompressionSession config

- Profile: `kVTProfileLevel_H264_High_AutoLevel`.
- `AverageBitRate`: derived from resolution × fps for the *recording* (not the export). Baseline: 1080p60 → ~12 Mbps, 1080p30 → ~6 Mbps. Hardcoded for now; the user-facing bitrate choice lives on the export preset, not the recording.
- `AllowFrameReordering: false` — no B-frames during live capture (lower latency, fine for editor scrubbing).
- `RealTime: true` — favor speed over compression ratio.
- `EnableHardwareAcceleratedVideoEncoder: true`.
- `RequireHardwareAcceleratedVideoEncoder: true` — fail loudly if HW encoder unavailable rather than silently dropping to software.

### What gets removed from `video_encoder.dart`

- `addFrame(Uint8List, int)` — Dart no longer sees per-frame data during recording.
- Temp-frame-files state machine.
- PCM concatenation logic.
- FFmpeg finalize call for raw recordings (FFmpeg stays in the *export* path).

### What `video_encoder.dart` becomes

A thin façade that calls into `ScreenRecorderPlatform.instance.startLiveRecording(settings)` / `stopLiveRecording() → RecordingResult` and reports the resulting MP4 path back to `RecordingController`. Cursor and frame counters stay where they are (not on the encoder's hot path).

### Failure handling

- VTCompressionSession init fails: surface error to `RecordingController`, refuse to start, show user-visible message. Pattern is already in place per the `feat: propagate video encoder initialization errors to user` commit.
- AVAssetWriter fails mid-recording: capture session stopped, partial file closed cleanly, error surfaced.
- Frame drops at the capture queue: `queueDepth` stays at 5; bump only if instrumentation shows drops.

### Expected gains

- Recording-thread CPU: native pixel-buffer copy gone, cursor renderer gone, isolate-message-send gone → likely well under 10% on capture for 1080p60.
- Recording memory: bounded by AVAssetWriter's internal buffer (single-digit MB) instead of accumulating frames in flight → comfortably under 500 MB for 30 min.
- Disk write rate: ~6-12 Mbps encoded vs. ~1.4 Gbps raw BGRA — **~150× reduction in disk bandwidth.**

## Export pipeline

The compositor isolate is unchanged; the changes are at the front (decode source MP4) and the back (HW-encode the result).

### Shape

```
recording.mp4  +  CursorRecording  +  user's effect choices
       │
       ▼
┌─ FFmpeg decode subprocess ─────────────────────────┐
│ ffmpeg -i recording.mp4 -f rawvideo -pix_fmt bgra  │
│        -                                            │
└────────────────────┬───────────────────────────────┘
                     │ stdout: BGRA frames @ N×W×H×4
                     ▼
        ┌─ Existing compositor isolate ──┐
        │  cursor_renderer (overlay)     │
        │  background_effect             │
        │  zoom_transformer              │
        │  window_frame compositor       │
        └────────────────┬───────────────┘
                         │ composited BGRA frames
                         ▼
┌─ FFmpeg encode subprocess ─────────────────────────┐
│ ffmpeg -f rawvideo -pix_fmt bgra -s WxH -r N -i -  │
│        -i recording.mp4 -map 0:v -map 1:a:0        │
│        -c:v h264_videotoolbox -b:v <preset>        │
│        -c:a copy export.mp4                        │
└────────────────────────────────────────────────────┘
```

### Key changes

- Two FFmpeg processes piped through the Dart isolate as the middle stage. Decode emits raw BGRA on stdout; Dart reads, composites, writes; encode reads from stdin.
- Audio passes through unchanged: `-c:a copy` from the source MP4 — no re-encode (AVAssetWriter already wrote AAC). Saves time and quality.
- `-c:v h264_videotoolbox` replaces `libx264`. This is the actual HW encoder switch.
- Bitrate from the chosen export preset, same logic as today (`export_preset.dart` is unchanged).

### Compositor isolate

Code in `processing/video_processing_isolate.dart`, `rendering/cursor_renderer.dart`, `effects/*` is **unchanged**. Differences: (1) source frames now come from FFmpeg's stdout instead of pre-spooled `.bgra` files; (2) cursor + effects are *always* applied at this stage (currently cursor is conditionally applied; in this design it's always the export-time path).

### Why FFmpeg stays

- FFmpeg already handles export presets (Twitter aspect ratios, GIF, downscaling). Replacing it would mean reimplementing all of that.
- `h264_videotoolbox` is FFmpeg's wrapper around VideoToolbox. Using it via FFmpeg gives us HW encoding without writing native export code.
- One subprocess on each side; stdin/stdout pipes; the rest is existing Dart code.

### Failure handling

- FFmpeg decode fails (corrupt input): surface error, suggest re-recording.
- FFmpeg encode fails (HW encoder unavailable mid-export): retry once with `libx264` software fallback, log a warning. Export still completes, slower.
- Compositor isolate exception per-frame: log, drop the frame, continue (existing behavior).

### Expected gain

- Encode stage: `h264_videotoolbox` is typically 5-10× faster than `libx264` at comparable quality. A 5-minute 1080p30 recording that currently exports in ~10 minutes should drop to ~1-2 minutes.
- Decode stage: FFmpeg's H.264 decoder is fast; on Apple Silicon it auto-uses VideoToolbox decode. Unlikely to be the bottleneck.

## Editor preview

The editor needs to overlay cursor + chosen effects on top of the pure-source video, since they're no longer baked in. Existing pattern: zoom is already applied at preview time via a `Transform` widget over `video_player`. We extend that idiom.

### Widget tree

```
Stack
├── VideoPlayerWidget                    (unchanged — plays recording.mp4)
├── Transform (zoom)                      (unchanged)
├── BackgroundEffectLayer                 (new — paints solid/gradient/blur behind video)
├── CursorOverlayPainter                  (new — CustomPaint, syncs to player position)
└── WindowFrameLayer                      (new — paints corners/shadow on top)
```

### `CursorOverlayPainter`

- A `CustomPaint` driven by listening to `videoPlayerController.value.position` changes (existing pattern in this codebase).
- On `paint(canvas, size)`: looks up cursor position at `currentTime` from `CursorRecording`, paints a cursor sprite at the right place (with click ripple animation if the chosen cursor effect is enabled).
- ~50-100 lines of code.

### Background / window-frame layers

- These are already painted in the editor today (frame customization UI has live preview per the `feat: add frame renderer with live preview` commit). The work is wiring the existing frame renderer to *always* sit above the video player, instead of only in the customization preview pane.
- Background effects (blur, gradient, solid) are paint operations on the area surrounding the video — exactly how Screen Studio-style framing works.

### Shared rendering helpers (drift mitigation)

To avoid preview-vs-export drift, extract pure functions used by both paths:

- `rendering/cursor_geometry.dart` *(new)* — `CursorPosition cursorAt(CursorRecording, Duration t)`, `Offset screenToVideoSpace(...)`.
- `effects/effect_params.dart` *(new)* — convert user-facing settings into concrete paint parameters (sigma, radius, color stops).

Both the preview's `CustomPainter` and the export-time isolate's compositor call into these helpers. If the math changes, both paths update simultaneously.

### Audio

`video_player` handles AAC playback natively. No work needed.

### Scrub / seek

Position-driven painters update on `positionStream`. Scrub responsiveness equals today's — the new layers redraw as the player seeks.

### Legacy recordings

When the user opens a recording made before Phase 9 (cursor already baked in), we'd render cursor twice. Mitigation: a `recording_meta.json` next to the MP4 with a `isPureSource: true|false` flag. The editor checks the flag and skips the cursor overlay for legacy files.

## Instrumentation

Minimal-viable, always on. One summary log line at end of recording, one at end of export.

### Recording-end summary

Emitted on `stopRecording()` via `app_logger`'s `Recording` zone:

```
[Recording] summary: duration=125.4s frames=7524 expectedFrames=7530
            droppedFrames=6 (0.08%) actualFps=60.0
            cpuPctAvg=4.2 cpuPctP95=7.1 memPeakMB=84
            outputBytes=156000000 (1.2GB/h equiv)
[Recording] verdict: cpuPct≤10 ✓  memPeak≤500MB ✓  fps=60 ✓  drops≤1% ✓  -> PASS
```

Sources:

- `duration`, `frames`: existing `RecordingController` state.
- `expectedFrames`: `round(duration * settings.fps)`.
- `droppedFrames`: `kVTEncodeInfo_FrameDropped` flag from VTCompressionSession, accumulated natively, returned with the stop response.
- `cpuPctAvg`, `cpuPctP95`: `host_processor_info` (mach kernel API) sampled every 1s natively.
- `memPeakMB`: `task_info(TASK_BASIC_INFO)` sampled every 1s, track max.
- `outputBytes`: file size of the resulting MP4.

All sampling done natively to avoid perturbing Dart isolates. One Stopwatch-style timer in Swift, returns a small struct on stop.

### Export-end summary

Emitted at the end of `VideoEncoder.export()`:

```
[Export] summary: inputDuration=125.4s exportWallTime=18.7s
         realtimeMultiple=6.7x (HW encoder: yes)
         decodeMs/frame=2.1 compositeMs/frame=4.3 encodeMs/frame=1.4
         outputBytes=85000000 outputCodec=h264_videotoolbox
[Export] verdict: realtimeMultiple≥1.0 ✓  -> PASS
```

Sources:

- `exportWallTime`: `Stopwatch` around the export call.
- `realtimeMultiple`: `inputDuration / exportWallTime`.
- `decodeMs/frame`, `compositeMs/frame`, `encodeMs/frame`: three `Stopwatch`es around FFmpeg-decode read, isolate composite call, FFmpeg-encode write. Per-stage view is cheap and answers "*why* did we miss the target" in the same line.
- `outputCodec`: known from the FFmpeg invocation (`h264_videotoolbox` if HW path succeeded, `libx264` if we fell back).

### Implementation surface

- `utils/perf_summary.dart` *(new)* — two small classes (`RecordingPerfSummary`, `ExportPerfSummary`) that hold fields and have a `format()` method.
- `RecordingController` accumulates timing during recording, calls `appLogger.recording.info(summary.format())` on stop.
- `VideoEncoder.export()` does the same with the export summary.
- One new method on `ScreenRecorderPlatform`: `Future<NativePerfStats> getRecordingPerfStats()` called once on stop, returns `{droppedFrames, cpuSamples, memPeakBytes}`.

Total: ~150 lines across native sampling, Dart summary classes, and plumbing.

## Scope and migration

### In scope (this phase)

- macOS live HW encode path (VTCompressionSession + AVAssetWriter).
- macOS export HW encode path (`h264_videotoolbox` via FFmpeg — works wherever the FFmpeg build supports it).
- Editor preview overlay (cursor + effects) — cross-platform, all-Flutter, no native work.
- Perf instrumentation — Dart side cross-platform; native CPU/mem sampling macOS-only.

### Stubbed for Windows/Linux

- The new `LiveRecordingWriter` interface in `screen_recorder_platform_interface` gets a default implementation that throws `UnsupportedError`. Windows/Linux platform plugins continue to use the existing spool-based path. They'll be ported in a follow-up phase.
- Native CPU/memory sampling reports zeros / "unavailable" on non-macOS.
- The `isPureSource` recording metadata flag lets the editor handle both formats.

### Migration of existing recordings

- Pre-Phase-9 recordings lack the metadata flag → editor treats them as legacy (cursor baked in, skip cursor overlay). No data migration, no loss.
- New macOS recordings get `isPureSource: true` and the new editor flow.
- Windows/Linux recordings stay on the legacy flow until those platforms are ported. Editor handles them identically to pre-Phase-9 macOS recordings.

## Testing strategy

### Unit tests

- `cursor_geometry.dart` pure functions — input cursor recording + time → expected screen position.
- `effect_params.dart` pure functions — settings → paint params.
- Perf summary `format()` methods — golden string output.

### Integration tests (real Mac required)

- **Recording**: start a 5-second recording of a known test pattern, stop, assert the resulting MP4 is valid, has audio, has expected duration ±100 ms, contains an `H264` track.
- **Export**: take a pre-recorded fixture MP4, run export with each preset, assert output is valid and roughly the expected size.
- **Perf regression**: record a known-length test pattern, parse the summary line, assert verdict is PASS.

### Manual

`MANUAL_TESTING_CHECKLIST.md` gains a "Phase 9 verification" section: record 1 minute, check log summary, verify all verdicts PASS. Open in editor, verify cursor overlay tracks correctly, verify effects apply, export, verify export summary PASS.

## Success criteria

- **Recording 1080p60**: CPU avg ≤10%, memory peak ≤500 MB for 30 min, dropped frames ≤1%.
- **Export 1080p30 with default effects**: ≥1.0× real-time multiple. Stretch: ≥5×.
- **Both summary log lines emit `-> PASS`** on a fresh test recording on a representative Mac.

## Open follow-ups (not in this phase)

- Windows live HW encode (Media Foundation `IMFSinkWriter` + `IMFTransform` for H.264).
- Linux live HW encode (FFmpeg with `h264_vaapi`, or PipeWire-native if available).
- Buffer pooling at the native layer (if instrumentation shows allocation pressure).
- GPU-shaded effects (Metal compute shaders) for export (if compositor stage becomes the bottleneck).
- Replacing FFmpeg in the export path with native AVAssetReader/Writer (option B from brainstorming — only if FFmpeg subprocess overhead becomes meaningful).
