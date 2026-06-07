# Camera (facecam) — design

## Summary

Capture the user's webcam alongside the screen recording as a **separate `.camera.mov`
sidecar file**, show a **live self-view** bubble on screen while recording, and let the
editor place the camera as a **picture-in-picture (PiP) bubble** driven by a **camera
timeline lane of regions**. Each region carries its own position, size, and visibility;
the bubble glides/resizes between regions and is hidden in the gaps. The camera is
composited into both the editor preview and the export so the output matches the preview
pixel-for-pixel. Look controls are **shape, roundness, mirror, border, shadow, opacity**.

The camera is **opt-in per recording**. Recordings made without it (and all existing
recordings) are completely unaffected: no camera sidecar ⇒ no camera lane, no camera
inspector tab.

This is a net-new feature, not part of the original five-part 2026-05-28 backlog (whose
only remaining item is **E — distribution/packaging**). Camera and captions were the two
candidate next features; camera was chosen first.

## Goals

- Record the webcam during a screen recording, decoupled from the primary screen MP4.
- Let the user frame themselves live (self-view) while recording.
- Place and animate the camera as a PiP bubble in the editor with full per-segment control.
- Composite the camera identically in preview and export.
- Never let a camera problem (permission denial, no device, mid-recording unplug) corrupt
  or interrupt the primary screen recording.

## Non-goals (v1) / future work

- Side-by-side / "scene" layouts where the **screen** shrinks to make room for the camera.
  v1 is PiP overlay only. (A region can be sized up to cover the screen, which gives a
  "full camera" moment without a dedicated mode.)
- A dedicated full-camera-mode toggle (distinct region type).
- Background removal (Apple Vision person segmentation) — genuinely useful but the heaviest
  item; deferred to a follow-up.
- Per-region **shape** overrides (shape/roundness/style are global in v1).
- A separate camera **audio** track (microphone is already its own feature; the camera is
  video-only).
- A capture **resolution picker** (v1 caps at 1080p, see §2).

## Key decisions (locked during brainstorming)

1. **Separate track, editor-composited** — the camera is never burned into the screen
   video. Mirrors how mic + system audio already work.
2. **Live self-view while recording** — a floating, draggable camera bubble so the user can
   frame themselves; fully repositionable later in the editor.
3. **Shape + roundness control** — Shape = the crop frame (`Square / Horizontal / Vertical /
   Original / Circle`); Roundness = corner-radius slider applied to the rectangular shapes.
   Circle is always fully round (roundness control greys out).
4. **Full per-segment timeline control** — a camera lane of regions; each region has its own
   position/size/visibility; the bubble glides between regions; gaps = hidden.
5. **PiP overlay only** for v1.
6. **v1 extras:** mirror (default ON), border + shadow styling, opacity. Background removal
   deferred.
7. **Storage:** a separate `.camera.mov` sidecar (not a 4th muxed track, not a raw-frame
   dump), anchored to the screen writer's host-time origin so camera-PTS == screen-time.

Three implementation calls made by the designer and approved:
- (a) 1080p capture cap, **no** resolution picker in v1.
- (b) shape/roundness/style are **global**; only position/size/visibility are per-region.
- (c) the live self-view's final on-screen position **seeds** the editor's first region.

## Architecture overview

The camera feature threads through the same five layers the screen + audio pipeline already
uses. Each layer has one clear job and a narrow interface to the next.

```
  ┌─ Capture (native macOS) ──────────────────────────────────────────────┐
  │  CameraCaptureManager (AVCaptureSession → AVCaptureVideoDataOutput)    │
  │    ├─► sidecar AVAssetWriter  → <recording>.camera.mov                 │
  │    └─► self-view NSPanel (AVCaptureVideoPreviewLayer, draggable)       │
  └───────────────────────────────────────────────────────────────────────┘
                │ method channel (cameraDevice in RecordingSettings)
  ┌─ Recording control (Dart) ────────────────────────────────────────────┐
  │  Camera chip in recording bar · prefs · writes <recording>.camera.json │
  └───────────────────────────────────────────────────────────────────────┘
                │ sidecar files (.camera.mov + .camera.json)
  ┌─ Editor model (slipreel_engine) ──────────────────────────────────────┐
  │  CameraSettings (global look)  +  CameraTrack / CameraRegion (timeline)│
  └───────────────────────────────────────────────────────────────────────┘
                │
  ┌─ Editor UI (screen_recorder) ─────────────────────────────────────────┐
  │  Camera timeline lane · on-canvas draggable bubble · inspector tab     │
  └───────────────────────────────────────────────────────────────────────┘
                │
  ┌─ Render ──────────────────────────────────────────────────────────────┐
  │  Preview: 2nd video player, position-synced, Flutter overlay          │
  │  Export:  2nd FfmpegDecoder → FrameCompositor camera pass             │
  └───────────────────────────────────────────────────────────────────────┘
```

## 1. Capture layer (native macOS)

**New class `CameraCaptureManager`** (in `screen_recorder_macos/macos/Classes/`), modeled
on the existing capture managers. It owns an `AVCaptureSession` with an `AVCaptureDevice`
video input and an `AVCaptureVideoDataOutput` producing `CMSampleBuffer`s on its own
dispatch queue. Two consumers:

1. **Sidecar writer.** A dedicated `AVAssetWriter` writing `<recording>.camera.mov`
   (H.264, passthrough/encoded). Its session is **anchored to the screen writer's host-time
   session origin** — the same `mach`-time → nanoseconds origin `LiveRecordingWriter` uses
   for the screen track. Result: a camera frame captured at host-time `T` is written with
   PTS `T − origin`, identical to how the screen track is timed, so **camera PTS == screen
   source-time** and editor alignment is a no-op. The existing **pause/resume `pausedOffset`
   rebasing** is applied to camera samples identically, so paused spans are elided from the
   camera track in lockstep with the screen track.

2. **Self-view window.** A borderless, always-on-top `NSPanel` (same window family as the
   recording bar) hosting an `AVCaptureVideoPreviewLayer`, circular-masked, **draggable** by
   the user. It appears during the 3-2-1 countdown and persists through recording,
   independent of the bar's bar↔pill mode. On stop, its final position is converted to a
   **normalized canvas position** and returned so the editor can seed the first region.

**Device selection & quality.** Enumerate cameras via `AVCaptureDevice.DiscoverySession`
(video). Default = system default device. Capture at the device's native resolution **capped
to 1080p**, frame rate capped to the recording fps. No user-facing resolution picker in v1.

**Permissions.** Add `NSCameraUsageDescription` to `screen_recorder/macos/Runner/Info.plist`.
Request access with `AVCaptureDevice.requestAccess(for: .video)`, routed through the existing
`PermissionsController` bus + `PermissionDeniedSheet` flow (the same path microphone uses).

**Insertion points / reused machinery:** host-time origin + `pausedOffset` from
`LiveRecordingWriter`; permission bus + deny-sheet from the first-run sub-project; window
family from `MainFlutterWindow`/the bar panel.

## 2. Recording control (Dart)

- **Platform interface:** add a nullable `cameraDevice` field to the platform-level
  `RecordingSettings` (sibling to `microphone` / `systemAudio`); plumb it through
  `startLiveRecording` args to the native plugin, which instantiates `CameraCaptureManager`
  when present.
- **Recording bar:** a **Camera control chip** mirroring the mic chip — shows the selected
  device (or "Off"), tap opens a native device menu (`showCameraMenu`) built from the
  discovery session. Selection persisted in the recording-settings store.
- **Sidecar metadata:** on stop, write `<recording>.camera.json` =
  `{ deviceName, width, height, fps, frameCount, selfViewPosition }`. Its **presence** is the
  editor's signal that a camera track exists for this recording.

## 3. Editor model (slipreel_engine)

- **`CameraSettings`** — the global *look*, stored on `EditorProjectState`:
  `enabled`, `shape` (`square | horizontal | vertical | original | circle`),
  `roundness` (0..1), `mirror` (default true), `borderWidth`, `borderColor`,
  `shadow` (bool/params), `opacity` (0..1). Full `copyWith` / `toJson` / `fromJson` /
  `==` / `hashCode`.

- **`CameraTrack`** — a track in `Timeline`, parallel to `ZoomTrack`, holding an ordered list
  of **`CameraRegion`**:
  `CameraRegion { Duration startTime; Duration endTime; Rect rect; }`
  where `rect` is the **normalized** position + size of the bubble on the output canvas
  (origin + extent in 0..1 space). Regions do not overlap; **gaps mean the camera is hidden**.
  Between two adjacent regions the bubble **animates** position + size, reusing the existing
  zoom easing/interpolation machinery (so a move from bottom-right → top-left glides).

  Aspect ratio of the rendered frame comes from the **global** `shape`; `rect` controls
  placement + scale. (Per the locked decision, shape/roundness/style are not per-region.)

- **Default seeding.** On first editor open when a `.camera.json` exists and
  `cameraTrack` is empty: inject one `CameraRegion` spanning the whole video at the
  self-view's saved normalized position (fallback: bottom-right), default size ≈ 22% of
  canvas width, then **save immediately** so it becomes user-owned (mirrors the auto-zoom
  seeding pattern — deletions stick on subsequent opens).

- Persistence rides the existing `.editor.json` sidecar / `EditorProjectState` plumbing.

## 4. Editor UI (screen_recorder)

- **Camera timeline lane** — a new lane alongside the keystroke / zoom / clip lanes. Renders
  one bar per `CameraRegion`; supports drag-to-move-in-time, edge-resize, click-to-select,
  add/remove, and dragging a region to leave a gap (a hidden span). Follows the established
  lane patterns (reveal animation, ruler alignment).
- **On-canvas bubble** — the camera bubble on the preview canvas is draggable with
  corner-resize handles; editing it writes the **selected** region's `rect`. Live preview of
  shape/roundness/border/shadow/opacity from `CameraSettings`.
- **Inspector "Camera" tab** — enable toggle; Shape chips (`Square / Horizontal / Vertical /
  Original / Circle`); Roundness slider (greyed out when shape = Circle); Mirror toggle;
  Border (width + color); Shadow toggle; Opacity slider; plus region list/selection. The tab
  is disabled/hidden when the recording has no camera sidecar. Reuses the existing
  `InspectorToggle` / `InspectorSlider` widgets and the springy-rail patterns.

## 5. Preview rendering

A **second video-player instance** loads `<recording>.camera.mov` and is **position-synced**
to the primary player — its seek / play / pause / playback-rate are slaved to the main
player so the two stay frame-aligned (camera-PTS == screen-source-time makes this a direct
mapping). It is drawn as a Flutter overlay above the screen video: `ClipPath` (or a shape
clipper) for the selected shape + roundness, transformed to the **active region's `rect`**
(interpolated between regions for the glide), with mirror (horizontal flip), border, shadow,
and opacity applied. When no camera region is active at the playhead, the overlay is not drawn.

## 6. Export compositing

Video compositing in this app is done in Flutter (`FrameCompositor`, RGBA out), not ffmpeg
filtergraphs. So the camera is composited the same way the cursor/keystroke overlays are:

- `FrameCompositor` opens a **second `FfmpegDecoder`** for `<recording>.camera.mov`.
- For each output frame at source-time `t`, it pulls the aligned camera frame and applies, in
  order: **mirror → shape crop → roundness mask → border → shadow → opacity**, then paints it
  at the **interpolated region `rect`** as a new pass *after* the keystroke layer. This keeps
  export pixel-for-pixel identical to preview.
- If no region is active at `t`, the camera pass is skipped for that frame.
- The ffmpeg **audio** filtergraph is unchanged — the camera contributes no audio.

## 7. Error handling

- **Permission denied / no camera device:** recording proceeds **screen-only**; surface a
  warning via `AppAlerts`; no camera sidecar is written.
- **Device unplugged mid-recording:** the camera writer finalizes whatever it has; the screen
  recording continues untouched (the core benefit of the sidecar split). The editor shows the
  camera for the span that exists.
- **Missing / corrupt `.camera.mov` on editor open:** camera tab disabled, non-fatal log
  (`AppLogger`), editor still opens normally.
- **Camera decode failure during export:** skip the camera pass, finish the export, surface a
  warning rather than failing the whole render.

## 8. Testing

- **Unit (slipreel_engine):** region interpolation / glide math; gap = hidden; default-seed
  placement + canvas clamping; `CameraSettings` / `CameraRegion` json round-trip + equality;
  PTS-alignment offset math.
- **Widget (screen_recorder):** camera lane (region render, drag/resize, gap creation);
  inspector tab enable/disable + control state; on-canvas handles edit the selected region's
  `rect`.
- **Manual (real Mac launch):** self-view appears / drags / seeds the first region; A/V +
  camera stay in sync across pause/resume; unplug camera mid-record → screen recording
  survives, camera covers the recorded span; export matches preview; a recording with the
  camera off shows no lane / disabled tab; permission-denied path records screen-only with a
  warning.
- **Native compile-check** via the `xcodebuild … -destination 'platform=macOS,arch=x86_64'
  build` route (since `flutter build macos` is broken in this environment).

## Open implementation notes

- The preview's second video player must be torn down / re-synced correctly across editor
  navigation and scrubbing; reuse the primary player's lifecycle hooks.
- Region interpolation should share code with zoom-region interpolation where practical to
  avoid a second easing implementation.
- The self-view → editor seed converts native window coordinates to normalized canvas space;
  clamp so the seeded region is fully on-canvas.
