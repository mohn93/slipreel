# Slipreel

A macOS screen recorder and editor. Capture full display, a window, or
a drawn region; cut, trim, speed-warp, and zoom-emphasize slices in
the editor; export to MP4 or GIF.

> Built with Flutter on macOS. The repo folder is named
> `screenflow_studio` for historical reasons; the app and brand are
> Slipreel (`com.slipreel.app`).

## Status

Pre-release. Used daily by the author; not yet packaged for distribution
(no DMG/sign/notarize/auto-update pipeline — that's the next sub-project).

## Capture

- **Sources**: full display, single window, or a user-drawn region.
- **Cursor**: optional capture of the system cursor; per-recording
  cursor track stored as a JSON sidecar for editor-time motion blur,
  recorded-click highlights, and auto-zoom focal points.
- **Audio**: mic + system audio captured as two independent tracks
  via a dedicated `SCStream`; both editable in the editor with per-track
  volume / mute and merged via `ffmpeg amix` on export.
- **Reliability**: fragmented MP4 (5s `movieFragmentInterval`),
  `SessionMarker` store, NDJSON cursor checkpoints, and a
  `RecoveryService` that re-muxes an interrupted recording's
  fragments on cold launch.
- **Controls**: 3-2-1 countdown, pause/resume (PTS-rebased — paused
  time is excluded from the timeline), global `Cmd+Shift+1/2/P`
  hotkeys, sleep auto-pause/wake modal, 30/60/90/120-minute duration
  warnings.

## Edit

- **Cut tool**: `Cmd+K` splits at the playhead. Each `ClipSlice`
  carries its own trim, playback speed, and inherits the project's
  shared cursor / animation config.
- **Zoom regions**: tap an empty zoom-lane spot to add a 2.5s 1.5x
  zoom; drag edges to resize; ramp dividers for enter/exit easings;
  auto-zoom detection seeds zooms on first open by walking
  `isClicked` rising edges.
- **Output aspect**: per-project `OutputAspect` (Auto + 6 ratios)
  drives canvas dimensions for preview AND export via
  `OutputCanvasResolver` — preview matches export bit-exact.
- **Timeline**: 1x-8x zoom via slider + trackpad pinch +
  `Cmd ±/Cmd+Shift+=`, anchor-preserving; ruler in edited time;
  slice ticks scale density by playback speed.
- **Inspector**: tabs for slice (trim/speed/audio/cursor), zoom region
  (level/enter/exit), animation/blur, output canvas, project alerts.

## Export

- **MP4**: per-slice ffmpeg filter graph (`setpts` for video,
  `atempo` chain for audio at any speed), full editor state honored.
- **GIF**: shared filter graph with palette generation, three quality
  tiers.

## Architecture

```
packages/
  screen_recorder/                  ── Flutter app (UI, state, project store)
  slipreel_engine/                  ── pure-Dart timeline, edited-time
                                       math, export pipelines
  screen_recorder_macos/            ── Swift plugin (ScreenCaptureKit,
                                       AVAssetWriter, VideoToolbox)
  screen_recorder_platform_interface
  screen_recorder_linux/windows     ── stubs
```

**Tech stack**: Flutter 3.41.5, Dart 3, Riverpod 2, Material 3,
ScreenCaptureKit + AVFoundation + CoreMedia (Swift), `ffmpeg` for
export.

## Development

```bash
fvm flutter pub get
fvm flutter run -d macos
```

Tests (211 across all packages):

```bash
cd packages/screen_recorder && fvm flutter test
cd packages/slipreel_engine && fvm flutter test
```

Native plugin changes require a full rebuild — hot reload swaps Dart
only. `flutter build macos` is broken on the local arm64 destination;
compile-check Swift changes with:

```bash
cd packages/screen_recorder_macos/example/macos
xcodebuild -workspace Runner.xcworkspace -scheme Runner \
  -destination 'platform=macOS,arch=x86_64' build
```

## License

Private. All rights reserved.
