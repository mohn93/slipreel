# Camera Plan 3 — Export Compositing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Composite the camera PiP bubble into the exported MP4 so the output matches the editor preview pixel-for-pixel.

**Architecture:** Compositing is done in Dart (`FrameCompositor`, RGBA out), not ffmpeg filtergraphs. We add a camera pass that, for each output frame at source-time `t`, resolves the active `CameraPlacement` (same `CameraPlacementResolver` the preview uses, glide included), pulls the time-aligned camera frame from a second `FfmpegDecoder` over `<recording>.camera.mov` (CFR-resampled to the pipeline fps), and paints it — mirror → cover-crop → shape clip → border → shadow → opacity — onto the **final, unzoomed** canvas, on top of everything. Geometry math is shared with the preview's `CameraBubble._pixelBox` so the two cannot drift. Camera is **canvas-fixed (never zoomed)**, contributes **no audio**, and a decode failure degrades gracefully (skip the pass, finish the export, surface a warning).

**Tech Stack:** Dart, `dart:ui` Canvas/Picture/Image, `FfmpegDecoder`, Riverpod-held `EditorProjectState`, `flutter test` (incl. golden tests). No native changes (so the broken `flutter build macos` path is avoided).

---

## Key facts (verified against the code, 2026-06-08)

- **Compositor entry:** `packages/slipreel_engine/lib/export/frame_compositor.dart` — `FrameCompositor.compose({required Uint8List videoFrameBgra, required Duration position})` returns `Future<Uint8List>` (RGBA). It builds a wallpaper image + a zoom-`Transform`ed foreground (frame chrome, video, cursor), composites them, and returns bytes. `totalSize` (the output canvas, even-rounded) is resolved via `OutputCanvasResolver.resolve(...)`.
- **`position` is raw screen-source-time `t`** — the same time base the zoom transform and cursor sample at, and the same base `CameraRegion.startTime/endTime` live in (camera regions behave like zoom regions). Per-slice trim/speed/cut is applied **downstream** by ffmpeg, not in the compositor, so we sample camera at raw `t` exactly like zoom.
- **`compose()` is called once per output frame in increasing `position`** (monotonic) — `export_pipeline.dart` compose stage: `t = Duration(microseconds: (1e6 * index) ~/ pipelineFps)`.
- **Camera frame alignment:** `screen_time = camera_time + offsetMicros` (`camera_playback_sync.dart:18`), so the camera frame for output time `t` is at camera-time `t - offsetMicros`. With the camera stream CFR-resampled to `pipelineFps`, the camera frame index for output index `i` is `i - offsetFrames`, where `offsetFrames = (offsetMicros * pipelineFps / 1e6).round()`.
- **Camera is canvas-fixed, NOT zoomed** (`playback_canvas.dart:712`). Export must paint it in **plain canvas coordinates** (outside the zoom `Transform`), on top of the composited frame.
- **Sidecar:** `CameraSidecarMeta.loadForVideo(videoPath)` → `<videoPath>.camera.json` (fields incl. `width`, `height`, `frameCount`, `offsetMicros`); movie at `CameraSidecarMeta.moviePathForVideo(videoPath)` = `<videoPath>.camera.mov`. **Export does not load this yet.**
- **`FfmpegDecoder`** (`packages/slipreel_engine/lib/export/ffmpeg_decoder.dart`): `FfmpegDecoder({required String inputPath, required int width, required int height, int? cfrFps})`, `Stream<Uint8List> frames()` yields raw **BGRA** frames of `width*height*4` bytes at constant cadence when `cfrFps` is set. No random access — consume sequentially.
- **Render contract (exact, from `CameraBubble`):**
  - Pixel box (`camera_bubble.dart:68-86`): `w = size*canvasW`; `aspect = shape.pixelAspect(originalAspect)`; `h = w/aspect`; pad = `kCameraEdgeMargin` (`0.06`) per axis; clamp center so edges stay inset, else center if too big.
  - Clip: `ClipOval` when `shape.isRound` (circle), else `ClipRRect` radius `roundness.clamp(0,1) * min(w,h)/2`.
  - Cover crop: source frame (aspect `originalAspect`) scaled `BoxFit.cover` to fill the box.
  - Mirror: horizontal flip about box center when `settings.mirror`.
  - Border: `Border.all(color: Color(settings.borderColor), width: settings.borderWidth)` when `borderWidth > 0`.
  - Shadow: `BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0,6))` when `settings.shadow`.
  - Opacity: `settings.opacity.clamp(0,1)`.
  - **Export decision:** export applies the **glide** (it's in `placementAt`) but NOT the UI-only vanish/appear *reveal* (blur+slide+fade). Visibility is a hard cut at region boundaries (`placementAt` returns `null` in gaps → skip the pass). Document this in code comments.
- **`CameraPlacementResolver.placementAt(Duration position, List<CameraRegion> regions, {...})` → `CameraPlacement?`** (`camera_placement_resolver.dart`). `null` = hidden. `CameraPlacement` has `centerX, centerY, size`.

## File structure

- **Create** `packages/slipreel_engine/lib/export/camera_frame_source.dart` — owns the camera `FfmpegDecoder`, maps output source-time → aligned camera BGRA frame, degrades on error.
- **Create** `packages/slipreel_engine/lib/rendering/camera_frame_painter.dart` — pure Canvas painter implementing the render contract.
- **Modify** `packages/slipreel_engine/lib/editor/camera_snap.dart` — add shared `cameraPixelBox(...)`.
- **Modify** `packages/screen_recorder/lib/ui/widgets/camera/camera_bubble.dart` — `_pixelBox()` delegates to `cameraPixelBox` (parity guarantee).
- **Modify** `packages/slipreel_engine/lib/export/frame_compositor.dart` — accept camera inputs; paint the camera pass.
- **Modify** `packages/slipreel_engine/lib/export/export_pipeline.dart` — load sidecar, build `CameraFrameSource`, pass to compositor; collect warnings.
- **Modify** `ExportPerfSummary` (wherever defined) — add `warnings`.
- **Modify** the export caller in `packages/screen_recorder` — surface `warnings` via `AppAlerts`.
- **Tests** under each package's `test/` mirror.

---

### Task 1: Shared camera pixel-box geometry

**Files:**
- Modify: `packages/slipreel_engine/lib/editor/camera_snap.dart`
- Test: `packages/slipreel_engine/test/editor/camera_snap_test.dart`

- [ ] **Step 1: Write the failing test** (append to `camera_snap_test.dart`)

```dart
group('cameraPixelBox', () {
  test('clamps the box inside the edge margin', () {
    const canvas = Size(1000, 500);
    // size 0.2 over width 1000 => w=200; square shape => h=200
    final box = cameraPixelBox(
      centerX: 1.0, centerY: 1.0, size: 0.2,
      canvasSize: canvas, shapeAspect: 1.0,
    );
    // pad = 0.06*1000=60 (x), 0.06*500=30 (y); hiX = 1000-100-60=840
    expect(box.width, closeTo(200, 1e-6));
    expect(box.height, closeTo(200, 1e-6));
    expect(box.center.dx, closeTo(840, 1e-6)); // clamped to hiX
    expect(box.center.dy, closeTo(500 - 100 - 30, 1e-6)); // hiY=370
  });

  test('centers the box when it is larger than the padded canvas', () {
    const canvas = Size(400, 400);
    // size 1.0 => w=400 == canvas width; loX(=200+24=224) > hiX(=400-200-24=176)
    final box = cameraPixelBox(
      centerX: 0.1, centerY: 0.1, size: 1.0,
      canvasSize: canvas, shapeAspect: 1.0,
    );
    expect(box.center.dx, closeTo(200, 1e-6));
    expect(box.center.dy, closeTo(200, 1e-6));
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/editor/camera_snap_test.dart`
Expected: FAIL — `cameraPixelBox` undefined.

- [ ] **Step 3: Implement `cameraPixelBox`** (add to `camera_snap.dart`; mirror `CameraBubble._pixelBox` exactly)

```dart
/// The camera bubble's pixel rect on a `canvasSize` canvas, given a normalized
/// center + width-fraction and the shape's pixel aspect. Clamps the box so its
/// edges stay [marginX]/[marginY] inset from the canvas edge (default
/// [kCameraEdgeMargin]); if the box is larger than the padded canvas on an
/// axis, it is centered on that axis. This is the single source of truth shared
/// by the editor preview (CameraBubble) and the export compositor.
Rect cameraPixelBox({
  required double centerX,
  required double centerY,
  required double size,
  required Size canvasSize,
  required double shapeAspect,
  double marginX = kCameraEdgeMargin,
  double marginY = kCameraEdgeMargin,
}) {
  final w = size * canvasSize.width;
  final aspect = (shapeAspect.isFinite && shapeAspect > 0) ? shapeAspect : 1.0;
  final h = w / aspect;
  final padX = marginX * canvasSize.width;
  final padY = marginY * canvasSize.height;
  final loX = w / 2 + padX, hiX = canvasSize.width - w / 2 - padX;
  final loY = h / 2 + padY, hiY = canvasSize.height - h / 2 - padY;
  final cx = loX <= hiX
      ? (centerX * canvasSize.width).clamp(loX, hiX).toDouble()
      : canvasSize.width / 2;
  final cy = loY <= hiY
      ? (centerY * canvasSize.height).clamp(loY, hiY).toDouble()
      : canvasSize.height / 2;
  return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
}
```

(`camera_snap.dart` already imports `dart:ui`/`package:flutter` for `Offset`/`Size`; if `Rect`/`Size` aren't in scope, add `import 'package:flutter/painting.dart' show Rect, Size, Offset;` consistent with the file's existing imports.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/editor/camera_snap_test.dart`
Expected: PASS.

- [ ] **Step 5: Refactor `CameraBubble._pixelBox` to delegate** (parity guarantee)

In `packages/screen_recorder/lib/ui/widgets/camera/camera_bubble.dart`, replace the body of `_pixelBox()` with:

```dart
Rect _pixelBox() => cameraPixelBox(
      centerX: placement.centerX,
      centerY: placement.centerY,
      size: placement.size,
      canvasSize: canvasSize,
      shapeAspect: settings.shape.pixelAspect(originalAspect),
    );
```

(`camera_snap.dart` is already imported in this file.)

- [ ] **Step 6: Run the camera bubble tests**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/camera/camera_bubble_test.dart`
Expected: PASS (positions unchanged).

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/editor/camera_snap.dart \
        packages/slipreel_engine/test/editor/camera_snap_test.dart \
        packages/screen_recorder/lib/ui/widgets/camera/camera_bubble.dart
git commit -m "refactor(camera): share cameraPixelBox between preview and export"
```

---

### Task 2: `CameraFrameSource` — time-aligned camera frames for export

**Files:**
- Create: `packages/slipreel_engine/lib/export/camera_frame_source.dart`
- Test: `packages/slipreel_engine/test/export/camera_frame_source_test.dart`

**Design:** A small class that consumes a CFR (`pipelineFps`) BGRA frame stream of `<recording>.camera.mov` monotonically and answers `frameAt(Duration outputSourceTime)` by advancing to camera index `round(t*fps) - offsetFrames`. Returns `null` before the camera starts (`target < 0`), after it ends (stream exhausted), or permanently after a decode error (sets `failed = true`, logs once). The frame stream is **injected** (a `Stream<Uint8List>`), so the production path passes `FfmpegDecoder(...).frames()` and tests pass a synthetic stream.

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/camera_frame_source.dart';

void main() {
  Uint8List frame(int tag) => Uint8List.fromList([tag, tag, tag, 255]);

  Stream<Uint8List> streamOf(List<int> tags) async* {
    for (final t in tags) yield frame(t);
  }

  test('aligns output time to the camera frame index (no offset)', () async {
    // fps=10 => frameDur=100ms. tags 0..4 are camera frames at indexes 0..4.
    final src = CameraFrameSource(
      frames: streamOf([0, 1, 2, 3, 4]),
      fps: 10,
      offsetMicros: 0,
    );
    expect(await src.frameAt(const Duration(milliseconds: 0)), frame(0));
    expect(await src.frameAt(const Duration(milliseconds: 250)), frame(2)); // round(0.25*10)=3? -> see note
    expect(await src.frameAt(const Duration(milliseconds: 400)), frame(4));
    await src.dispose();
  });

  test('applies the offset and clamps before-start / after-end to null',
      () async {
    // offsetMicros=200000 (200ms) => offsetFrames=2 at fps=10.
    // cameraIndex = round(t*10) - 2.
    final src = CameraFrameSource(
      frames: streamOf([10, 11, 12]),
      fps: 10,
      offsetMicros: 200000,
    );
    expect(await src.frameAt(const Duration(milliseconds: 0)), isNull); // idx -2
    expect(await src.frameAt(const Duration(milliseconds: 200)), frame(10)); // idx 0
    expect(await src.frameAt(const Duration(milliseconds: 400)), frame(12)); // idx 2
    expect(await src.frameAt(const Duration(milliseconds: 600)), isNull); // exhausted
    await src.dispose();
  });

  test('monotonic advance never rewinds (returns last frame for repeats)',
      () async {
    final src = CameraFrameSource(frames: streamOf([0, 1, 2]), fps: 10, offsetMicros: 0);
    expect(await src.frameAt(const Duration(milliseconds: 200)), frame(2));
    // an earlier time can't rewind a forward-only stream → returns current frame
    expect(await src.frameAt(const Duration(milliseconds: 0)), frame(2));
    await src.dispose();
  });
}
```

> **Implementer note on rounding:** define the camera index as `(t.inMicroseconds * fps / 1e6).round() - offsetFrames`. Recompute the test's expected values from that exact formula and fix the inline comments so they match (e.g. `round(0.25*10)=3` ⇒ frame(3), not frame(2)). The *behaviors* under test (alignment, offset, before/after-range → null, no-rewind) are what matter; make the literals consistent with the implemented formula.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/camera_frame_source_test.dart`
Expected: FAIL — `CameraFrameSource` undefined.

- [ ] **Step 3: Implement `CameraFrameSource`**

```dart
import 'dart:async';
import 'dart:typed_data';

/// Maps export output source-time to the time-aligned camera frame.
///
/// The camera movie is decoded as a constant-fps (`fps`) BGRA stream and
/// consumed monotonically. For an output frame at source-time `t`, the aligned
/// camera frame index is `round(t*fps) - offsetFrames`, where
/// `offsetFrames = round(offsetMicros*fps/1e6)` (screen_time = camera_time +
/// offsetMicros). Returns null before the camera starts, after it ends, or once
/// a decode error has disabled the source.
class CameraFrameSource {
  CameraFrameSource({
    required Stream<Uint8List> frames,
    required this.fps,
    required int offsetMicros,
  })  : _it = StreamIterator(frames),
        _offsetFrames = (offsetMicros * fps / 1e6).round();

  final int fps;
  final int _offsetFrames;
  final StreamIterator<Uint8List> _it;

  int _consumed = -1; // index of the frame currently in _current
  Uint8List? _current;
  bool _exhausted = false;
  bool _failed = false;

  bool get failed => _failed;

  /// The aligned camera frame for output source-time [t], or null when hidden
  /// (before start / after end / source failed).
  Future<Uint8List?> frameAt(Duration t) async {
    if (_failed) return null;
    final target = (t.inMicroseconds * fps / 1e6).round() - _offsetFrames;
    if (target < 0) return null;
    while (_consumed < target && !_exhausted) {
      try {
        if (!await _it.moveNext()) {
          _exhausted = true;
          break;
        }
        _current = _it.current;
        _consumed++;
      } catch (_) {
        _failed = true;
        _current = null;
        return null;
      }
    }
    if (_consumed < target) return null; // ran past the end
    return _current;
  }

  Future<void> dispose() => _it.cancel();
}
```

- [ ] **Step 4: Run the test to verify it passes** (after reconciling literals)

Run: `cd packages/slipreel_engine && flutter test test/export/camera_frame_source_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/camera_frame_source.dart \
        packages/slipreel_engine/test/export/camera_frame_source_test.dart
git commit -m "feat(camera): CameraFrameSource maps export time to aligned camera frames"
```

---

### Task 3: `CameraFramePainter` — pure Canvas render of the bubble

**Files:**
- Create: `packages/slipreel_engine/lib/rendering/camera_frame_painter.dart`
- Test: `packages/slipreel_engine/test/rendering/camera_frame_painter_test.dart` (golden)

**Contract:** `paint` draws into a `Canvas` at `pixelBox`, in order: opacity layer → shadow → (clip) cover-cropped, mirrored image → border. Use exact constants from the render contract.

- [ ] **Step 1: Write the failing golden test**

```dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/rendering/camera_frame_painter.dart';

Future<ui.Image> solidImage(int w, int h, Color c) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec)..drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = c);
  return rec.endRecording().toImage(w, h);
}

Future<ui.Image> render(CameraSettings settings, double originalAspect) async {
  final cam = await solidImage(160, 120, const Color(0xFF3366FF));
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 300, 200),
      Paint()..color = const Color(0xFF101010)); // bg
  CameraFramePainter.paint(
    canvas,
    image: cam,
    pixelBox: const Rect.fromLTWH(90, 50, 120, 100),
    settings: settings,
    originalAspect: originalAspect,
    opacity: settings.opacity,
  );
  return rec.endRecording().toImage(300, 200);
}

void main() {
  testWidgets('circle bubble matches golden', (tester) async {
    final img = await render(
      const CameraSettings(shape: CameraShape.circle, mirror: false,
          shadow: true, borderWidth: 4, borderColor: 0xFFFFFFFF),
      160 / 120,
    );
    await expectLater(img, matchesGoldenFile('goldens/camera_circle.png'));
  });

  testWidgets('rounded-rect bubble matches golden', (tester) async {
    final img = await render(
      const CameraSettings(shape: CameraShape.horizontal, roundness: 0.5,
          mirror: true, shadow: false, borderWidth: 0),
      160 / 120,
    );
    await expectLater(img, matchesGoldenFile('goldens/camera_rrect.png'));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/camera_frame_painter_test.dart`
Expected: FAIL — `CameraFramePainter` undefined.

- [ ] **Step 3: Implement `CameraFramePainter`**

```dart
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/camera_settings.dart';

/// Paints the camera bubble onto [canvas] at [pixelBox], pixel-for-pixel with
/// the editor preview (`CameraBubble`): opacity → shadow → shape-clipped,
/// cover-cropped, optionally mirrored image → border. Canvas-space only; the
/// caller positions it (unzoomed) on the final composited frame.
class CameraFramePainter {
  static void paint(
    ui.Canvas canvas, {
    required ui.Image image,
    required Rect pixelBox,
    required CameraSettings settings,
    required double originalAspect,
    required double opacity,
  }) {
    final o = opacity.clamp(0.0, 1.0);
    if (o <= 0) return;
    final isRound = settings.shape.isRound;
    final radius = isRound
        ? pixelBox.shortestSide / 2
        : settings.roundness.clamp(0.0, 1.0) * (pixelBox.shortestSide / 2);
    final rrect = RRect.fromRectAndRadius(pixelBox, Radius.circular(radius));

    // Opacity over the whole bubble.
    canvas.saveLayer(
        pixelBox.inflate(40), Paint()..color = Color.fromRGBO(0, 0, 0, o));

    // Shadow (matches BoxShadow(0x66000000, blur 18, offset (0,6))).
    if (settings.shadow) {
      final sigma = _blurRadiusToSigma(18.0);
      final shadowPaint = Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma);
      final shifted = rrect.shift(const Offset(0, 6));
      if (isRound) {
        canvas.drawOval(shifted.outerRect, shadowPaint);
      } else {
        canvas.drawRRect(shifted, shadowPaint);
      }
    }

    // Clip to shape, then draw the cover-cropped, optionally-mirrored image.
    canvas.save();
    if (isRound) {
      canvas.clipPath(Path()..addOval(pixelBox));
    } else {
      canvas.clipRRect(rrect);
    }
    final src = _coverSrcRect(image, originalAspect, pixelBox);
    if (settings.mirror) {
      canvas.save();
      canvas.translate(pixelBox.center.dx, 0);
      canvas.scale(-1, 1);
      canvas.translate(-pixelBox.center.dx, 0);
    }
    canvas.drawImageRect(
        image, src, pixelBox, Paint()..filterQuality = FilterQuality.medium);
    if (settings.mirror) canvas.restore();
    canvas.restore(); // clip

    // Border (stroke centered on the edge, like Border.all).
    if (settings.borderWidth > 0) {
      final bp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = settings.borderWidth
        ..color = Color(settings.borderColor);
      if (isRound) {
        canvas.drawOval(pixelBox, bp);
      } else {
        canvas.drawRRect(rrect, bp);
      }
    }

    canvas.restore(); // opacity layer
  }

  // BoxFit.cover source crop: the largest centered sub-rect of [image] (whose
  // aspect is [originalAspect]) matching the destination box's aspect.
  static Rect _coverSrcRect(ui.Image image, double originalAspect, Rect dst) {
    final iw = image.width.toDouble(), ih = image.height.toDouble();
    final dstAspect = dst.width / dst.height;
    double sw, sh;
    if (dstAspect > iw / ih) {
      sw = iw;
      sh = iw / dstAspect;
    } else {
      sh = ih;
      sw = ih * dstAspect;
    }
    return Rect.fromCenter(
        center: Offset(iw / 2, ih / 2), width: sw, height: sh);
  }

  // Flutter's BoxShadow blur-radius → sigma conversion.
  static double _blurRadiusToSigma(double radius) => radius * 0.57735 + 0.5;
}
```

> Use the image's true pixel dimensions for the cover crop (more robust than `originalAspect`); keep `originalAspect` in the signature for parity/needs and to match the preview's contract. If the implementer finds the preview relies on `originalAspect` rather than the texture's own size, prefer the texture size here since the decoded camera frame carries real dimensions.

- [ ] **Step 4: Generate goldens, then verify**

Run: `cd packages/slipreel_engine && flutter test --update-goldens test/rendering/camera_frame_painter_test.dart`
Then re-run without the flag: `flutter test test/rendering/camera_frame_painter_test.dart`
Expected: PASS. **Spec-review the generated PNGs by eye** against the preview (circle clip, mirror, border, shadow) before accepting.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/camera_frame_painter.dart \
        packages/slipreel_engine/test/rendering/camera_frame_painter_test.dart \
        packages/slipreel_engine/test/rendering/goldens/
git commit -m "feat(camera): CameraFramePainter renders the bubble on a Canvas"
```

---

### Task 4: Paint the camera pass in `FrameCompositor`

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Test: `packages/slipreel_engine/test/export/frame_compositor_camera_test.dart`

**Integration:** Add constructor params `CameraFrameSource? cameraFrameSource` and `double cameraOriginalAspect` (regions + settings come from `projectState`). In `compose()`, after the wallpaper+foreground are composited into the final canvas/recorder but **before** `endRecording()` (i.e. in plain, unzoomed canvas space, on top), do:

```dart
final cs = projectState.cameraSettings;
final src = cameraFrameSource;
if (cs.enabled && src != null) {
  final placement = CameraPlacementResolver.placementAt(
      position, projectState.cameraRegions);
  if (placement != null) {
    final bgra = await src.frameAt(position);
    if (bgra != null) {
      final image = await _bgraToImage(bgra, cameraSrcWidth, cameraSrcHeight);
      final box = cameraPixelBox(
        centerX: placement.centerX,
        centerY: placement.centerY,
        size: placement.size,
        canvasSize: totalSize,
        shapeAspect: cs.shape.pixelAspect(cameraOriginalAspect),
      );
      CameraFramePainter.paint(finalCanvas,
          image: image,
          pixelBox: box,
          settings: cs,
          originalAspect: cameraOriginalAspect,
          opacity: cs.opacity);
      image.dispose();
    }
  }
}
```

- Reuse the compositor's existing BGRA→`ui.Image` helper (the same one used for the screen frame — find it; if it's private/inlined, factor a `_bgraToImage(bytes,w,h)`); the camera source pixel dims come from the sidecar (`cameraMeta.width/height`), passed in as `cameraSrcWidth/Height` (add as constructor params, or carry the meta).
- `finalCanvas` is the recorder that draws wallpaper then foreground (the unzoomed composite). If the no-wallpaper branch returns the foreground image directly, restructure so the camera is always painted in unzoomed canvas space on the final image (e.g. always composite into a final recorder when a camera pass is active).

- [ ] **Step 1: Write the failing test** — a compositor with a stub `CameraFrameSource` (synthetic 1×1-scaled solid frames) and a single full-canvas camera region produces output whose center-of-bubble pixel differs from a camera-disabled render; with `cameraSettings.enabled = false` the two outputs are identical.

```dart
// Build an EditorProjectState with one CameraRegion covering [0, 1s], a
// CameraSettings(enabled: true, shape: square, size big), a stub
// CameraFrameSource yielding a solid red BGRA frame, and assert the composed
// RGBA has red near the bubble center; then enabled:false → no red there.
```

(Construct `FrameCompositor` with a tiny `videoSize`, a green screen frame, and `position = 0`. Use `CameraFrameSource(frames: <one red frame>, fps: fps, offsetMicros: 0)`. Read a pixel from the returned RGBA at the bubble's center and assert R dominates.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_camera_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement** the constructor params + the camera pass above. Keep audio and all existing layers untouched.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_camera_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full engine export tests** to ensure no regression.

Run: `cd packages/slipreel_engine && flutter test test/export`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/slipreel_engine/test/export/frame_compositor_camera_test.dart
git commit -m "feat(camera): composite the camera pass into export frames"
```

---

### Task 5: Plumb the sidecar into `ExportPipeline` + warnings

**Files:**
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart`
- Modify: `ExportPerfSummary` (find its definition; likely `export_pipeline.dart` or a sibling)
- Test: `packages/slipreel_engine/test/export/export_pipeline_camera_test.dart` (light — see note)

- [ ] **Step 1: Add `warnings` to `ExportPerfSummary`** — `final List<String> warnings;` (default `const []`), included in its constructor. Add a unit test asserting the field round-trips/defaults.

- [ ] **Step 2: Load the sidecar in `run()`** — near where `sourcePath`/decoder are set up:

```dart
final cameraMeta = await CameraSidecarMeta.loadForVideo(sourcePath);
final cameraMoviePath = CameraSidecarMeta.moviePathForVideo(sourcePath);
final cameraEnabled = cameraMeta != null &&
    projectState.cameraSettings.enabled &&
    projectState.cameraRegions.isNotEmpty &&
    await File(cameraMoviePath).exists();

CameraFrameSource? cameraSource;
double cameraOriginalAspect = 1.0;
if (cameraEnabled) {
  cameraOriginalAspect = cameraMeta!.height == 0
      ? 1.0
      : cameraMeta.width / cameraMeta.height;
  final camDecoder = FfmpegDecoder(
    inputPath: cameraMoviePath,
    width: cameraMeta.width,
    height: cameraMeta.height,
    cfrFps: pipelineFps,
  );
  cameraSource = CameraFrameSource(
    frames: camDecoder.frames(),
    fps: pipelineFps,
    offsetMicros: cameraMeta.offsetMicros,
  );
}
```

Pass `cameraFrameSource: cameraSource`, `cameraOriginalAspect`, and the camera source dims into the `FrameCompositor` constructor. After the encode loop, if `cameraSource?.failed == true`, append a warning: `'Camera could not be decoded; exported without the camera overlay.'` Surface `warnings` in the returned `ExportPerfSummary`. Wrap the camera-source construction/usage so any failure cannot abort the export (the `CameraFrameSource` already degrades to `null` frames; ensure a decoder spawn failure is caught and converted to a warning).

- [ ] **Step 3: Test (light).** A full end-to-end ffmpeg export is heavy/environment-bound; instead assert the **gating logic** is correct via a small extracted pure helper, e.g.:

```dart
bool shouldCompositeCamera({
  required bool hasSidecar,
  required bool enabled,
  required bool hasRegions,
  required bool movieExists,
}) => hasSidecar && enabled && hasRegions && movieExists;
```

Extract that helper, unit-test its truth table, and call it from `run()`. (Keeps the decision testable without spawning ffmpeg.)

- [ ] **Step 4: Run engine tests**

Run: `cd packages/slipreel_engine && flutter test test/export`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/export_pipeline.dart \
        packages/slipreel_engine/test/export/
git commit -m "feat(camera): load the camera sidecar in export + warn on decode failure"
```

---

### Task 6: Surface export warnings in the app

**Files:**
- Modify: the export caller in `packages/screen_recorder` (find where `ExportPipeline().run(...)` / `ExportPerfSummary` is consumed — search `ExportPerfSummary`, `\.run(` in `packages/screen_recorder/lib`)
- Test: extend the nearest existing export-controller/widget test if one exists; otherwise a focused widget/unit test of the mapping `warnings → AppAlerts.warning`.

- [ ] **Step 1: Write the failing test** — given a summary with a non-empty `warnings`, the caller invokes `AppAlerts.warning(...)` once per warning (or a single combined warning). Match the existing AppAlerts usage pattern in that file.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** — after a successful export, if `summary.warnings.isNotEmpty`, show them via `AppAlerts.warning(...)` (keep the existing success alert). Camera-off / no-sidecar exports produce no warnings (silent, correct).

- [ ] **Step 4: Run the test to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/... packages/screen_recorder/test/...
git commit -m "feat(camera): surface export warnings (camera decode failure) via AppAlerts"
```

---

### Task 7: Manual verification (real Mac) + memory update

Not automatable here (`flutter build macos` is broken; export needs ffmpeg + a real `.camera.mov`). Provide the human a checklist; do not block plan completion on it.

- [ ] **Step 1:** Export a recording that has a camera. Confirm the exported MP4's camera bubble matches the preview: placement per segment, shape, roundness, mirror, border, shadow, opacity, and the 350ms glide between touching regions; camera is **not** zoomed when a zoom region is active.
- [ ] **Step 2:** A recording with the camera **off** (or no `.camera.mov`) exports screen-only with no errors and no warning.
- [ ] **Step 3:** Simulate a decode failure (e.g. truncate the `.camera.mov`) → export still finishes, screen-only, with the camera-decode warning shown via AppAlerts.
- [ ] **Step 4:** Update `MEMORY.md` / `camera_facecam_subproject.md` to mark Plan 3 done and the camera feature complete end-to-end (capture → editor → export).

---

## Self-review notes

- **Spec coverage:** §6 export compositing → Tasks 3–5; §7 decode-failure error handling → Tasks 2/5/6; parity with §5 preview → Tasks 1/3; testing §8 → unit (Tasks 1,2,5) + golden (Task 3) + compositor (Task 4) + manual (Task 7).
- **Type consistency:** `cameraPixelBox` signature is identical in Task 1 and its callers (Tasks 1 refactor, 4). `CameraFrameSource(frames, fps, offsetMicros)` + `frameAt(Duration)` consistent across Tasks 2,4,5. `CameraFramePainter.paint(...)` signature consistent across Tasks 3,4.
- **Known soft spots flagged for the implementer:** exact rounding literals in Task 2's test comments (reconcile to the formula); whether the cover crop keys off the decoded image dims vs `originalAspect` (prefer real dims); the precise place in `compose()` where the *final unzoomed* canvas exists (restructure the no-wallpaper branch if needed). These are called out inline so the spec/quality reviewers check them.
