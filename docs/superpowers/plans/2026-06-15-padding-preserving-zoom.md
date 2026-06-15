# Padding-preserving Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a zoom is active, keep the wallpaper padding and rounded window frame fixed; magnify/pan only the recording content inside the fixed rounded window (clipped to the corners), in both preview and export.

**Architecture:** The zoom matrix (`ZoomTransformer.getTransform`) and focal/clamp logic are unchanged. We move *where* the transform applies: the frame chrome (shadow/ring/border) stops being zoomed, and the magnified video+cursor is clipped to the fixed, un-zoomed rounded video rect. Export = `frame_compositor.dart`; preview = `playback_canvas.dart`.

**Tech Stack:** Dart / Flutter; `flutter_test`; `dart:ui` Canvas/Picture; `Transform` + `ClipPath`/`clipRRect`.

**Spec:** `docs/superpowers/specs/2026-06-15-padding-preserving-zoom-design.md`

---

## File Structure

- **Modify** `packages/slipreel_engine/lib/export/frame_compositor.dart` — stop zooming the chrome; clip the zoomed video+cursor to the fixed rounded `_videoRect`. (Task 1)
- **Modify** `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — pull `FramePainter` out of the zoom `Transform`; wrap the zoomed video and cursor each in a fixed rounded clip (`ClipPath`) at the video window rect; add a small `CustomClipper`. (Task 2)
- **Test** `packages/slipreel_engine/test/export/frame_compositor_test.dart` — add a discriminating pixel test that the zoom does not grow the video into the padding. (Task 1)
- Manual runtime verification. (Task 3)

Run engine tests from `packages/slipreel_engine`, app tests from `packages/screen_recorder`, with `flutter test`.

---

### Task 1: Export — fixed frame + content-clipped zoom in `FrameCompositor`

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Test: `packages/slipreel_engine/test/export/frame_compositor_test.dart`

- [ ] **Step 1: Write the failing test**

Append this test inside the existing `group('FrameCompositor', () { ... })` in `frame_compositor_test.dart` (before the group's closing `});`). It reuses the file's `_meta` and `_solidBgra` helpers.

```dart
    test('active zoom does not grow the video into the padding '
        '(padding band stays clear)', () async {
      // 320×240 video, uniform 40px padding → totalSize 400×320, and the
      // video rect is (40,40,320,240). A solid-magenta video with a 2×
      // zoom centered on the video. With the fixed-frame model the
      // magnified video must stay clipped to the video rect, so a pixel
      // in the padding band (x<40) stays clear (transparent). With the
      // old whole-window scaling, the video would cover that pixel.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          windowFrame: const WindowFrame(
            name: 'Custom',
            padding: EdgeInsets.all(40),
            cornerRadius: 0, // square: sample points aren't near a corner
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
          zoomRegions: [
            ZoomRegion(
              rect: const Rect.fromLTWH(0, 0, 320, 240), // center (160,120)
              startTime: Duration.zero,
              duration: const Duration(seconds: 1),
              zoomLevel: 2.0,
              followCursor: false,
              enterDuration: Duration.zero,
              exitDuration: Duration.zero,
            ),
          ],
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
      );

      final magenta = _solidBgra(320, 240, 0xFF, 0x00, 0xFF);
      // Mid-region: 2× hold (no enter/exit ramp).
      final rgba = await compositor.compose(
        videoFrameBgra: magenta,
        position: const Duration(milliseconds: 500),
      );

      const w = 400; // totalSize width
      bool isMagenta(int x, int y) {
        final i = (y * w + x) * 4;
        // RGBA: magenta video reads R=0xFF, B=0xFF (see existing tests).
        return rgba[i + 0] == 0xFF && rgba[i + 2] == 0xFF && rgba[i + 3] == 0xFF;
      }

      // Window center is magnified video → magenta.
      expect(isMagenta(200, 160), isTrue,
          reason: 'window center should show the (magnified) video');
      // Left padding band (x=20 < 40) must NOT be covered by the video.
      expect(isMagenta(20, 160), isFalse,
          reason: 'padding must stay clear of the zoomed video');
      // Top padding band (y=20 < 40) likewise.
      expect(isMagenta(200, 20), isFalse,
          reason: 'top padding must stay clear of the zoomed video');
    });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_test.dart --plain-name "does not grow the video into the padding"`
Expected: FAIL — with the current whole-window scaling the magnified video covers the padding, so `isMagenta(20,160)` is `true` (assertion `isFalse` fails).

- [ ] **Step 3: Stop zooming the chrome**

In `frame_compositor.dart`, the chrome layer is currently built with the zoom applied (~lines 244–251):

```dart
      ui.Picture? chromePicture;
      if (_frame.name != 'None') {
        final chromeRecorder = ui.PictureRecorder();
        final chromeCanvas = ui.Canvas(chromeRecorder, layerRect);
        applyZoom(chromeCanvas);
        _framePainter.paint(chromeCanvas, totalSize);
        chromePicture = chromeRecorder.endRecording();
      }
```

Remove the `applyZoom(chromeCanvas);` line so the chrome paints crisp at the fixed padded rect:

```dart
      ui.Picture? chromePicture;
      if (_frame.name != 'None') {
        final chromeRecorder = ui.PictureRecorder();
        final chromeCanvas = ui.Canvas(chromeRecorder, layerRect);
        // Chrome (shadow/ring/border) stays at the FIXED padded rect — it
        // is not zoomed, so the window frame and padding don't move when
        // the camera pushes into the content.
        _framePainter.paint(chromeCanvas, totalSize);
        chromePicture = chromeRecorder.endRecording();
      }
```

- [ ] **Step 4: Clip the zoomed content to the fixed rounded video rect**

Still in `compose()`, the foreground (video + cursor) is currently built as (~lines 225–239):

```dart
      final fgRecorder = ui.PictureRecorder();
      final fgCanvas = ui.Canvas(fgRecorder, layerRect);
      applyZoom(fgCanvas);
      _paintVideoFrame(fgCanvas, videoImage);
      if (motion != null && !projectState.hideCursorOverlay) {
        final effectiveCursorBlur =
            projectState.motionBlur * projectState.cursorMovementBlur;
        _paintCursor(
          fgCanvas,
          position: position,
          intensity: effectiveCursorBlur,
          state: motion.state,
        );
      }
      final fgPicture = fgRecorder.endRecording();
```

Wrap the zoomed draws in a fixed (device-space, un-zoomed) rounded clip at `_videoRect`, engaged only when a zoom is actually active:

```dart
      final fgRecorder = ui.PictureRecorder();
      final fgCanvas = ui.Canvas(fgRecorder, layerRect);
      // When a zoom is active, clip the magnified content to the FIXED
      // (un-zoomed) rounded video rect so the window/padding stay put and
      // only the footage scales inside it. The clip is applied BEFORE the
      // zoom transform, so it stays anchored in canvas space. At identity
      // (no active zoom) we skip the clip to preserve current behavior —
      // notably the cursor's ability to bleed onto the padding near an edge.
      final zoomActive = !zoomTransform.isIdentity();
      if (zoomActive) {
        fgCanvas.save();
        fgCanvas.clipRRect(
          RRect.fromRectAndRadius(
            _videoRect,
            Radius.circular(_frame.cornerRadius),
          ),
        );
      }
      applyZoom(fgCanvas);
      _paintVideoFrame(fgCanvas, videoImage);
      if (motion != null && !projectState.hideCursorOverlay) {
        final effectiveCursorBlur =
            projectState.motionBlur * projectState.cursorMovementBlur;
        _paintCursor(
          fgCanvas,
          position: position,
          intensity: effectiveCursorBlur,
          state: motion.state,
        );
      }
      if (zoomActive) {
        fgCanvas.restore();
      }
      final fgPicture = fgRecorder.endRecording();
```

(Note: `_paintVideoFrame` keeps its own inner `clipRRect(_videoRect)` for the no-zoom path's rounded corners; under the new outer fixed clip it is harmlessly redundant because the outer clip is the tighter one in canvas space.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_test.dart --plain-name "does not grow the video into the padding"`
Expected: PASS.

- [ ] **Step 6: Run the full compositor test file (no regressions)**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_test.dart`
Expected: PASS (all tests — including the existing "shadowed frame + zooming pan" chrome-split smoke test and the "None"-frame zoom focal test).

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/slipreel_engine/test/export/frame_compositor_test.dart
git commit -m "feat(zoom): export keeps frame/padding fixed, zooms content inside the window (#zoom-padding)"
```

---

### Task 2: Preview — fixed frame + content-clipped zoom in `PlaybackCanvas`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`

Preview mirrors export: `FramePainter` leaves the zoom `Transform`; the magnified video and cursor are each clipped to the fixed rounded video window. The zoom matrix is unchanged, and the no-zoom branch (`focalUpdate == null`) is untouched.

- [ ] **Step 1: Add a clipper for the fixed rounded video window**

At the bottom of `playback_canvas.dart` (file scope, after the `_PlaybackCanvasState` class), add:

```dart
/// Clips a totalSize-sized child to the fixed (un-zoomed) rounded video
/// window. Used so the zoomed video/cursor content stays inside the
/// padded frame instead of scaling out over the wallpaper padding.
class _VideoWindowClipper extends CustomClipper<Path> {
  const _VideoWindowClipper(this.windowRect, this.cornerRadius);
  final Rect windowRect;
  final double cornerRadius;

  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(windowRect, Radius.circular(cornerRadius)),
    );

  @override
  bool shouldReclip(_VideoWindowClipper oldClipper) =>
      oldClipper.windowRect != windowRect ||
      oldClipper.cornerRadius != cornerRadius;
}
```

- [ ] **Step 2: Split the composition into chrome / video-layer / debug widgets**

In `build()`, the `composition` Stack (currently ~lines 908–1010) bundles `FramePainter`, the `Positioned` video, and the debug overlays. Replace the single `final composition = Stack(children: [...]);` with three named pieces plus the no-zoom composition built from them. Find the block that starts `final composition = Stack(` and ends at its matching `);` (the `]` then `);` after the debug `Builder`), and replace it with:

```dart
            // Frame chrome (shadow/ring/border/background). NOT zoomed in
            // the new model — it stays at the fixed padded rect.
            final framePainterLayer = CustomPaint(
              size: totalSize,
              painter: FramePainter(
                frame: currentFrame,
                videoSize: videoSize,
                aspect: widget.outputAspect,
              ),
            );

            // The video, positioned + rounded at the padded rect, wrapped
            // in a totalSize Stack so it can be fed through a Transform
            // (a bare Positioned can only live directly under a Stack).
            final videoLayer = SizedBox.fromSize(
              size: totalSize,
              child: Stack(
                children: [
                  Positioned(
                    left: videoOriginX,
                    top: videoOriginY,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        currentFrame.cornerRadius,
                      ),
                      child: SizedBox(
                        width: videoSize.width,
                        height: videoSize.height,
                        child: videoPlayer!,
                      ),
                    ),
                  ),
                ],
              ),
            );

            final debugLayers = <Widget>[
              if (widget.showZoomDebug)
                Positioned(
                  left: currentFrame.padding.left,
                  top: currentFrame.padding.top,
                  child: IgnorePointer(
                    child: SizedBox(
                      width: videoSize.width,
                      height: videoSize.height,
                      child: CustomPaint(
                        painter: ZoomFocalDebugPainter(
                          cursorRecording: widget.cursorRecording,
                          position: pos,
                          videoSize: videoSize,
                          smoothedFocal: _zoomFocalController.smoothedFocal,
                          activeZoom: focalUpdate?.zoom,
                          inFlight: _zoomFocalController.inFlight,
                          focalVelocity: _zoomFocalController.focalVelocity,
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.showZoomDebug && widget.debugSnapshot != null)
                Builder(builder: (_) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    final raw = cursorAt(widget.cursorRecording, pos);
                    final positions = widget.cursorRecording.positions;
                    (double, double)? xRange;
                    (double, double)? yRange;
                    if (positions.isNotEmpty) {
                      var minX = positions.first.x;
                      var maxX = positions.first.x;
                      var minY = positions.first.y;
                      var maxY = positions.first.y;
                      for (final p in positions) {
                        if (p.x < minX) minX = p.x;
                        if (p.x > maxX) maxX = p.x;
                        if (p.y < minY) minY = p.y;
                        if (p.y > maxY) maxY = p.y;
                      }
                      xRange = (minX, maxX);
                      yRange = (minY, maxY);
                    }
                    widget.debugSnapshot!.value = ZoomDebugSnapshot(
                      cursor: raw == null ? null : Offset(raw.x, raw.y),
                      smoothedFocal: _zoomFocalController.smoothedFocal,
                      activeZoom: focalUpdate?.zoom,
                      inFlight: _zoomFocalController.inFlight,
                      focalVelocity: _zoomFocalController.focalVelocity,
                      cursorVelocity: motion?.velocityPxPerSec ?? Offset.zero,
                      videoSize: videoSize,
                      cursorSampleCount: widget.cursorRecording.count,
                      position: pos,
                      cursorXRange: xRange,
                      cursorYRange: yRange,
                      lastSnapReason: _zoomFocalController.lastSnapReason,
                      lastSnapAt: _zoomFocalController.lastSnapAt,
                    );
                  });
                  return const SizedBox.shrink();
                }),
            ];

            // No-zoom composition (unchanged behavior): chrome + video +
            // debug, none of it transformed.
            final composition = Stack(
              children: [framePainterLayer, videoLayer, ...debugLayers],
            );
```

- [ ] **Step 3: Rework the active-zoom branch to clip+zoom only the content**

The active-zoom branch is the `TweenAnimationBuilder` whose `builder` currently produces `transformed` (the whole composition wrapped in a `Transform`) and `transformedCursor` (~lines 1037–1080). Replace the body of that `builder` (from `final tweenedRegion = ...` through the `return _buildSceneMotionBlurPass(...)`) with:

```dart
                final tweenedRegion = activeZoom.copyWith(
                  zoomLevel: animatedZoom,
                );
                final transform = _zoomTransformer.getTransform(
                  position: pos,
                  zoomRegion: tweenedRegion,
                  videoSize: videoSize,
                  focalPoint: focalForFrame,
                  rampCurve: activeZoom.rampCurveOverride?.toFlutterCurve() ??
                      widget.screenAnimationConfig.rampCurve,
                );

                // Fixed rounded clip at the video window. The magnified
                // video/cursor are clipped to this so the frame + padding
                // stay put and only the footage scales inside the window.
                final windowClipper = _VideoWindowClipper(
                  Rect.fromLTWH(
                    videoOriginX,
                    videoOriginY,
                    videoSize.width,
                    videoSize.height,
                  ),
                  currentFrame.cornerRadius,
                );

                // Body: un-zoomed chrome, then the clipped+zoomed video,
                // then un-zoomed debug. (transformChild is `composition`,
                // unused here — we compose the split layers directly so the
                // chrome stays out of the transform.)
                final transformed = Stack(
                  fit: StackFit.expand,
                  children: [
                    framePainterLayer,
                    ClipPath(
                      clipper: windowClipper,
                      child: Transform(
                        transform: transform,
                        alignment: Alignment.center,
                        child: videoLayer,
                      ),
                    ),
                    ...debugLayers,
                  ],
                );

                // Cursor goes through the same zoom + same fixed clip, but
                // OUTSIDE the scene-blur capture so the shader never smears
                // it (accumulation already blurs the cursor).
                final transformedCursor = cursorOverlay == null
                    ? null
                    : ClipPath(
                        clipper: windowClipper,
                        child: Transform(
                          transform: transform,
                          alignment: Alignment.center,
                          child: cursorOverlay,
                        ),
                      );

                return _buildSceneMotionBlurPass(
                  body: transformed,
                  cursorOverlay: transformedCursor,
                  keystrokeOverlayWidget: keystrokeOverlayWidget,
                  cameraOverlayWidget: cameraOverlayWidget,
                  stickyBackground: stickyBackground,
                  position: pos,
                  totalSize: totalSize,
                  videoSize: videoSize,
                  currentTransform: transform,
                );
```

Leave the `TweenAnimationBuilder(... child: composition, builder: (context, animatedZoom, transformChild) { ... })` wrapper as-is (it still passes `composition` as `transformChild`; the new body ignores it in favor of the split layers — that's intentional and harmless). The no-zoom early return `if (focalUpdate == null) { return _buildSceneMotionBlurPass(body: composition, cursorOverlay: cursorOverlay, ...); }` stays exactly as it is.

- [ ] **Step 4: Static-analyze**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/zoom/playback_canvas.dart`
Expected: No errors. (If the analyzer flags `transformChild` as unused, rename it to `_` in the builder signature: `builder: (context, animatedZoom, _) {`.)

- [ ] **Step 5: Run the preview widget tests (no regressions)**

Run: `cd packages/screen_recorder && flutter test test/ --plain-name "playback_canvas"`
Then the scene-blur tests: `cd packages/screen_recorder && flutter test test/ --plain-name "scene_blur"`
Expected: PASS. (These exercise the camera/latency/scene-blur tree; they must still build and pass with the restructured composition.)

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "feat(zoom): preview keeps frame/padding fixed, zooms content inside the window (#zoom-padding)"
```

---

### Task 3: Manual runtime verification

Automated coverage proves the export geometry and that preview builds; the visual result needs eyes. Use the flutter-qa probe (`boot_app`) per the project's runtime setup.

**Files:** none (verification only).

- [ ] **Step 1: Launch the app and open a recording in the editor**

Boot the app; open a recording that has a zoom region (or add one).

- [ ] **Step 2: The original repro — padding constant at high zoom**

Set a zoom to ~4× with the focal in a corner (e.g. top-right), as in the original report. Expected: the wallpaper padding border is the **same width** as at 1× — it does not shrink — and the rounded window frame stays put while the footage magnifies/pans inside it (clipped to the rounded corners).

- [ ] **Step 3: 1× unchanged**

Scrub to a 1× section (no active zoom). Expected: identical to before — including the cursor still able to sit slightly over the padding near a screen edge.

- [ ] **Step 4: Preview ↔ export agreement**

Export the project and scrub the MP4 across the zoom: the padding is constant and the content-zoom matches the preview.

- [ ] **Step 5: Scene-blur check (the flagged interaction)**

With screen motion blur enabled (`motionBlur` + `screenMovementBlur`/`screenZoomBlur` > 0), play through a zoom ramp. Watch the fixed frame/shadow: if the static border visibly smears during the ramp, note it — that's the flagged follow-up (confine the smear to the content layer). It does not block this change.

- [ ] **Step 6: Record the outcome**

Note the result in the PR/issue. No commit unless a fix was needed.

---

## Self-Review

**Spec coverage:**
- Stop zooming the chrome → Task 1 Step 3 (export), Task 2 Steps 2–3 (preview, chrome out of Transform). ✓
- Clip magnified content to the fixed rounded video rect → Task 1 Step 4 (export `clipRRect`), Task 2 Steps 1+3 (preview `ClipPath` + `_VideoWindowClipper`). ✓
- Cursor magnifies inside the clipped window, kept out of scene-blur capture → Task 2 Step 3 (`transformedCursor` clipped+zoomed, passed as `cursorOverlay`). ✓
- Wallpaper stays sticky → unchanged in both (export composites wallpaper un-zoomed; preview `stickyBackground` outside transform). ✓
- 1× / no-zoom unchanged → export `zoomActive` gate (Task 1 Step 4); preview `focalUpdate == null` branch untouched + `composition` unchanged (Task 2). ✓
- Scene-blur interaction verified, not expanded → Task 3 Step 5. ✓
- Testing: export pixel test (Task 1), preview build/analyze + existing widget tests (Task 2), manual repro (Task 3). ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**Type consistency:** `_VideoWindowClipper(windowRect, cornerRadius)` defined in Task 2 Step 1 and constructed in Step 3 with the same positional args. `zoomTransform`/`zoomActive` (export) are locals in `compose()`. `framePainterLayer`/`videoLayer`/`debugLayers`/`composition` defined in Task 2 Step 2 and consumed in Step 3 and the no-zoom branch. `transform` built identically to current via `_zoomTransformer.getTransform`. ✓
