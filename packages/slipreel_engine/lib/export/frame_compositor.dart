import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:flutter/services.dart' show rootBundle;
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/camera_render_resolver.dart';
import 'package:slipreel_engine/editor/camera_snap.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/effects/scene_motion_blur.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/export/camera_frame_source.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/camera_frame_painter.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';
import 'package:slipreel_engine/rendering/frame_painter.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// Re-renders the same composition the preview canvas paints, but to
/// raw RGBA bytes instead of a widget tree. Owns the same stateful
/// controllers the preview owns ([CursorMotionController],
/// [ZoomFocalController]) so smoothing / tween / deadzone semantics
/// stay identical between what the user sees in the editor and what
/// lands in the exported MP4.
///
/// One instance per export. [compose] must be called in monotonically
/// increasing [position] order — the focal/motion controllers carry
/// state across calls.
class FrameCompositor {
  FrameCompositor({
    required this.projectState,
    required this.cursorRecording,
    required this.metadata,
    required this.videoSize,
    required this.fps,
    this.cameraFrameSource,
    this.cameraOriginalAspect = 1.0,
    this.cameraSrcWidth = 0,
    this.cameraSrcHeight = 0,
  }) : _framePainter = FramePainter(
         frame: projectState.windowFrame,
         videoSize: videoSize,
         aspect: projectState.outputAspect,
       ),
       totalSize = _evenSize(
         OutputCanvasResolver.resolve(
           videoSize: videoSize,
           padding: projectState.windowFrame.padding,
           aspect: projectState.outputAspect,
         ).canvasSize,
       ),
       // Center the video inside the (even-rounded) canvas. The resolver
       // already positions the video rect; after rounding the canvas to
       // even pixel dimensions for yuv420p there can be up to 1px of
       // slack per axis — _centeredVideoRect redistributes that slack
       // symmetrically so the video stays centered.
       _videoRect = _centeredVideoRect(
         _evenSize(
           OutputCanvasResolver.resolve(
             videoSize: videoSize,
             padding: projectState.windowFrame.padding,
             aspect: projectState.outputAspect,
           ).canvasSize,
         ),
         videoSize,
       );

  final EditorProjectState projectState;
  final CursorRecording cursorRecording;
  final RecordingMetadata? metadata;

  /// Source video resolution in pixels (matches the decoder's frame size).
  final Size videoSize;

  /// Rate at which [compose] will be called, used to seed the FIR
  /// cursor smoother. The export pipeline drives this at the chosen
  /// `outputFps` so the smoother's window is sized against the rate
  /// the consumer (encoder) is actually reading at.
  final int fps;

  /// Time-aligned source of decoded camera (facecam) BGRA frames, or
  /// null when this recording has no camera sidecar. When non-null and
  /// [CameraSettings.enabled], the PiP bubble is composited on top of
  /// the final (non-zoomed) canvas — see [compose].
  final CameraFrameSource? cameraFrameSource;

  /// The source camera's pixel width/height aspect, forwarded to
  /// [CameraShape.pixelAspect] / [CameraFramePainter]. Defaults to 1.0
  /// (square) so a missing sidecar never yields a degenerate box.
  final double cameraOriginalAspect;

  /// Decoded camera frame dimensions in pixels (the BGRA buffer's
  /// width/height). 0 disables the camera pass even if a source is set.
  final int cameraSrcWidth;
  final int cameraSrcHeight;

  /// Output canvas size — the framed totalSize, rounded to even
  /// pixels (yuv420p subsampling requires it).
  final Size totalSize;

  final FramePainter _framePainter;
  final Rect _videoRect;

  /// Shared scene-state production for preview and export. Owns the
  /// spring controllers and EMA filter; one source of truth means
  /// preview and export cannot disagree on cursor velocity, focal
  /// trajectory, or filtered blur velocity.
  final ScenePassBuilder _scenePassBuilder = ScenePassBuilder();
  final ZoomTransformer _zoomTransformer = ZoomTransformer();
  DeterministicFocalTrack? _focalTrack;
  ui.FragmentProgram? _sceneBlurProgram;
  // The wallpaper is rendered once per export and reused for every
  // composited frame, since the wallpaper inputs (category/index/blur/
  // totalSize) don't change between calls to [compose]. Doing this
  // saves ~one image rasterization per frame.
  ui.Image? _cachedWallpaperImage;
  String? _cachedWallpaperKey;

  // Scene-blur knobs come from [MotionTuning] so the export pipeline
  // and the preview canvas share one source of truth. Reads are
  // instance accessors because [MotionTuning] fields aren't const-
  // exposable; the instance itself is `MotionTuning.defaults` (a
  // const) so there's no per-frame allocation.
  static final MotionTuning _tuning = MotionTuning.defaults;
  double get _sceneBlurExposureMs => _tuning.sceneBlurExposureMs;
  double get _sceneBlurMaxTranslation => _tuning.sceneBlurMaxTranslation;
  int get _sceneBlurSampleCount => _tuning.sceneBlurSampleCount;
  double get _sceneBlurSpeedCurveExp => _tuning.sceneBlurSpeedCurveExp;
  double get _sceneBlurSpeedCurveRefPx => _tuning.sceneBlurSpeedCurveRefPx;

  WindowFrame get _frame => projectState.windowFrame;

  /// Whether this recording has cursor data the overlay should paint.
  /// Mirrors PlaybackCanvas's `hasCursorData` test so legacy / window
  /// captures fall back to "video only" cleanly.
  bool get _hasCursorData =>
      metadata?.isPureSource == true && cursorRecording.count > 0;

  /// Compose one frame of the export.
  ///
  /// [videoFrameBgra] is the raw BGRA byte buffer for the source frame
  /// at [position] (the decoder's output). Returns RGBA bytes sized to
  /// [totalSize] — pipe directly to ffmpeg with
  /// [FfmpegPixelFormat.rgba].
  Future<Uint8List> compose({
    required Uint8List videoFrameBgra,
    required Duration position,
  }) async {
    final videoImage = await _bgraToImage(
      videoFrameBgra,
      videoSize.width.toInt(),
      videoSize.height.toInt(),
    );
    try {
      // Single source of truth shared with PlaybackCanvas: same spring
      // controllers, same gate semantics, same EMA filter. Anything
      // computed here is exactly what the preview sees.
      final scenePass = _scenePassBuilder.build(
        position: position,
        zoomRegions: projectState.zoomRegions,
        cursorAnimationConfig: projectState.cursorAnimationConfig,
        cursorDelay: projectState.cursorDelay,
        cursorPostProcess: projectState.cursorPostProcess,
        cursorRecording: cursorRecording,
        videoSize: videoSize,
        fps: fps,
        hasCursorData: _hasCursorData,
        screenRampCurve: projectState.screenAnimationConfig.rampCurve,
      );
      final motion = scenePass.motion;
      final focalUpdate = scenePass.focalUpdate;

      // Apply the zoom Transform around totalSize/2, matching the
      // preview's `Transform(alignment: Alignment.center, ...)`.
      // The matrix's translation is built against videoSize/2; the
      // arithmetic lands the focal at the alignment origin because
      // _videoRect centers the video inside totalSize, so
      // `_videoRect.left - totalSize.width/2 = -videoSize.width/2`.
      Matrix4 zoomTransform = Matrix4.identity();
      if (focalUpdate != null) {
        final ramp =
            focalUpdate.zoom.rampCurveOverride?.toFlutterCurve() ??
            projectState.screenAnimationConfig.rampCurve;
        zoomTransform = _zoomTransformer.getTransform(
          position: position,
          zoomRegion: focalUpdate.zoom,
          videoSize: videoSize,
          focalPoint: focalUpdate.focal,
          rampCurve: ramp,
        );
      }

      final sceneSignal = _computeSceneMotionSignal(position: position);

      // Apply the same zoom transform to any layer so it scales/pans with
      // the camera.
      void applyZoom(ui.Canvas c) {
        if (focalUpdate == null) return;
        c.translate(totalSize.width / 2, totalSize.height / 2);
        c.transform(zoomTransform.storage);
        c.translate(-totalSize.width / 2, -totalSize.height / 2);
      }

      final layerRect = Rect.fromLTWH(0, 0, totalSize.width, totalSize.height);

      // Foreground CONTENT (video + cursor) — the ONLY layer fed through the
      // scene-motion-blur smear. The frame chrome (shadow/ring/border) is
      // rendered crisp below: motion-blurring the soft drop shadow during an
      // enter/exit ramp spreads its darkness over a wider area and visibly
      // fades/lowers it ("the shadow hides on export"). The chrome still
      // scales/pans with the zoom; it just never gets the directional smear.
      // The wallpaper stays sticky (rendered separately below).
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

      // Frame chrome (shadow / inset ring / background / border) — crisp,
      // never smeared. Skipped for the 'None' frame (FramePainter draws
      // nothing, so there is no chrome to composite).
      ui.Picture? chromePicture;
      if (_frame.name != 'None') {
        final chromeRecorder = ui.PictureRecorder();
        final chromeCanvas = ui.Canvas(chromeRecorder, layerRect);
        applyZoom(chromeCanvas);
        _framePainter.paint(chromeCanvas, totalSize);
        chromePicture = chromeRecorder.endRecording();
      }

      try {
        final fgImage = await fgPicture.toImage(
          totalSize.width.toInt(),
          totalSize.height.toInt(),
        );
        final ui.Image? chromeImage = chromePicture == null
            ? null
            : await chromePicture.toImage(
                totalSize.width.toInt(),
                totalSize.height.toInt(),
              );
        try {
          // Smear the moving CONTENT only. The crisp chrome (shadow) and the
          // sticky wallpaper are composited un-blurred.
          final blurredFg = await _applySceneMotionBlur(fgImage, sceneSignal);
          final fgToComposite = blurredFg ?? fgImage;
          // Resolve + decode the camera PiP frame (async) BEFORE the
          // synchronous canvas draws below. The camera bubble is
          // canvas-fixed: it must NOT inherit the zoom transform, so it
          // is painted on the final, non-transformed composeCanvas on
          // top of everything else.
          ui.Image? cameraImage;
          Rect? cameraBox;
          double cameraReveal = 1.0;
          final cam = projectState.cameraSettings;
          final camSource = cameraFrameSource;
          if (cam.enabled && camSource != null) {
            // renderAt (not placementAt) so the bubble fades/blurs/slides in and
            // out at region edges — the vanish tail keeps drawing the (live)
            // camera at the last placement for 280ms after a region ends.
            final render = CameraRenderResolver.renderAt(
                position, projectState.cameraRegions);
            if (render != null) {
              final bgra = await camSource.frameAt(position);
              if (bgra != null && cameraSrcWidth > 0 && cameraSrcHeight > 0) {
                cameraImage =
                    await _bgraToImage(bgra, cameraSrcWidth, cameraSrcHeight);
                cameraReveal = render.reveal;
                cameraBox = cameraPixelBox(
                  centerX: render.placement.centerX,
                  centerY: render.placement.centerY,
                  size: render.placement.size,
                  canvasSize: totalSize,
                  shapeAspect: cam.shape.pixelAspect(cameraOriginalAspect),
                );
              }
            }
          }
          void paintCamera(ui.Canvas c) {
            final img = cameraImage, box = cameraBox;
            if (img != null && box != null) {
              CameraFramePainter.paint(c,
                  image: img,
                  pixelBox: box,
                  settings: cam,
                  opacity: cam.opacity,
                  reveal: cameraReveal);
            }
          }

          try {
            final wallpaperImage = await _ensureWallpaperImage();
            // No wallpaper, no chrome, AND no camera: the content IS the
            // final image. Skip the composite step.
            if (wallpaperImage == null &&
                chromeImage == null &&
                cameraImage == null) {
              final byteData = await fgToComposite.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              if (byteData == null) {
                throw StateError('toByteData returned null at $position');
              }
              return Uint8List.fromList(byteData.buffer.asUint8List());
            }
            // Composite bottom-to-top: sticky wallpaper, crisp frame chrome
            // (shadow/ring/border), the (possibly blurred) video+cursor
            // content, then the canvas-fixed camera bubble. The content
            // layer's transparent padding reveals the chrome (and wallpaper)
            // around the framed video.
            final composeRecorder = ui.PictureRecorder();
            final composeCanvas = ui.Canvas(
              composeRecorder,
              Rect.fromLTWH(0, 0, totalSize.width, totalSize.height),
            );
            if (wallpaperImage != null) {
              composeCanvas.drawImage(wallpaperImage, Offset.zero, Paint());
            }
            if (chromeImage != null) {
              composeCanvas.drawImage(chromeImage, Offset.zero, Paint());
            }
            composeCanvas.drawImage(fgToComposite, Offset.zero, Paint());
            paintCamera(composeCanvas);
            final composePicture = composeRecorder.endRecording();
            try {
              final finalImage = await composePicture.toImage(
                totalSize.width.toInt(),
                totalSize.height.toInt(),
              );
              try {
                final byteData = await finalImage.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                if (byteData == null) {
                  throw StateError('toByteData returned null at $position');
                }
                // Defensive copy — the underlying buffer is owned by
                // the ui.Image and freed when we dispose it.
                return Uint8List.fromList(byteData.buffer.asUint8List());
              } finally {
                finalImage.dispose();
              }
            } finally {
              composePicture.dispose();
            }
          } finally {
            cameraImage?.dispose();
            if (blurredFg != null) blurredFg.dispose();
          }
        } finally {
          fgImage.dispose();
          chromeImage?.dispose();
        }
      } finally {
        fgPicture.dispose();
        chromePicture?.dispose();
      }
    } finally {
      videoImage.dispose();
    }
  }

  /// Lazily renders the wallpaper into a `ui.Image` and caches it,
  /// keyed by the inputs that affect its appearance. Returns null when
  /// the project has no wallpaper. All frames of one export hit the
  /// cache after the first call, since wallpaperCategory/Index/blur and
  /// totalSize don't change mid-export.
  Future<ui.Image?> _ensureWallpaperImage() async {
    final category = _frame.wallpaperCategory;
    if (category == null) {
      _cachedWallpaperImage?.dispose();
      _cachedWallpaperImage = null;
      _cachedWallpaperKey = null;
      return null;
    }

    final key = '$category|${_frame.wallpaperIndex}|'
        '${_frame.backgroundBlur}|'
        '${totalSize.width.toInt()}x${totalSize.height.toInt()}';
    final cached = _cachedWallpaperImage;
    if (cached != null && _cachedWallpaperKey == key) return cached;

    _cachedWallpaperImage?.dispose();
    _cachedWallpaperImage = null;
    _cachedWallpaperKey = key;

    // Photo-based macOS wallpapers need the asset image preloaded as
    // a ui.Image before we can paint to the recorder canvas. `BoxPainter`
    // would otherwise kick off an async ImageStream that doesn't
    // resolve in time for our synchronous paint, and the export would
    // ship a blank wallpaper. Procedural categories (gradients / solid)
    // paint synchronously and use the BoxPainter path.
    final photo = await _loadWallpaperPhoto(category, _frame.wallpaperIndex);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      Rect.fromLTWH(0, 0, totalSize.width, totalSize.height),
    );
    _paintWallpaper(canvas, photo: photo);
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(
        totalSize.width.toInt(),
        totalSize.height.toInt(),
      );
      _cachedWallpaperImage = image;
      return image;
    } finally {
      picture.dispose();
      photo?.dispose();
    }
  }

  /// Loads the photo asset for [category]/[index] as a `ui.Image` if
  /// the category is image-backed, or returns null for procedural
  /// categories. Caller is responsible for disposing the returned
  /// image.
  Future<ui.Image?> _loadWallpaperPhoto(String category, int index) async {
    final assetPath = photoWallpaperAsset(category, index);
    if (assetPath == null) return null;
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: totalSize.width.toInt(),
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  // --- internals --------------------------------------------------------

  /// Returns a [DeterministicFocalTrack] for [region] if it is a
  /// follow-cursor region, caching it to avoid replaying the spring
  /// pipeline more than once per region identity. Returns null for
  /// non-follow-cursor regions (the caller uses rect.center instead).
  DeterministicFocalTrack? _trackFor(ZoomRegion region) {
    if (!region.followCursor) return null;
    final cached = _focalTrack;
    if (cached != null &&
        cached.matches(
          region: region,
          cursorRecording: cursorRecording,
          cursorAnimationConfig: projectState.cursorAnimationConfig,
          cursorPostProcess: projectState.cursorPostProcess,
          videoSize: videoSize,
          fps: fps,
          screenRampCurve: projectState.screenAnimationConfig.rampCurve,
        )) {
      return cached;
    }
    return _focalTrack = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: cursorRecording,
      cursorAnimationConfig: projectState.cursorAnimationConfig,
      cursorPostProcess: projectState.cursorPostProcess,
      videoSize: videoSize,
      fps: fps,
      screenRampCurve: projectState.screenAnimationConfig.rampCurve,
    );
  }

  /// Exposes [_computeSceneMotionSignal] for unit tests so they can
  /// assert the blur signal without driving the full GPU-backed [compose]
  /// pipeline (which requires a real video frame decoder).
  @visibleForTesting
  SceneMotionBlurSignal sceneMotionSignalAt(Duration position) =>
      _computeSceneMotionSignal(position: position);

  SceneMotionBlurSignal _computeSceneMotionSignal({
    required Duration position,
  }) {
    if (projectState.motionBlur <= 0 ||
        projectState.zoomRegions.isEmpty ||
        (projectState.screenMovementBlur <= 0 &&
            projectState.screenZoomBlur <= 0)) {
      return SceneMotionBlurSignal.zero;
    }

    final movementExposure = Duration(
      microseconds:
          (_sceneBlurExposureMs *
                  projectState.motionBlur *
                  projectState.screenMovementBlur *
                  1000)
              .round(),
    );
    final zoomExposure = Duration(
      microseconds:
          (_sceneBlurExposureMs *
                  projectState.motionBlur *
                  projectState.screenZoomBlur *
                  1000)
              .round(),
    );
    return SceneMotionBlurController.compute(
      position: position,
      sampleAt: _sceneSampleAt,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: _sceneBlurMaxTranslation,
    );
  }

  /// Stateless `(focal, scale)` at an arbitrary timestamp, mirroring
  /// the preview overlay's `_approxSampleAt`. Both `current` (at
  /// `position`) and `prev` (at `position − exposure`) flow through
  /// this function, so the smear vector is symmetric by construction:
  /// pause / play / scrub / export all see the same signal at the
  /// same playhead.
  SceneCameraSample _sceneSampleAt(Duration t) {
    if (t.isNegative) {
      return SceneCameraSample(
        position: t,
        focal: videoSize.center(Offset.zero),
        scale: 1.0,
      );
    }

    final active = ZoomRegion.activeAt(t, projectState.zoomRegions);
    if (active == null) {
      return SceneCameraSample(
        position: t,
        focal: videoSize.center(Offset.zero),
        scale: 1.0,
      );
    }

    Offset focal;
    if (!active.followCursor) {
      focal = active.rect.center;
    } else {
      final track = _trackFor(active);
      if (track != null) {
        focal = track.focalAt(t);
      } else {
        final s = cursorAtFiltered(
          cursorRecording,
          t,
          projectState.cursorPostProcess,
        );
        focal = s == null
            ? active.rect.center
            : Offset(
                s.x.toDouble().clamp(0, videoSize.width),
                s.y.toDouble().clamp(0, videoSize.height),
              );
      }
    }

    final matrix = _zoomTransformer.getTransform(
      position: t,
      zoomRegion: active,
      videoSize: videoSize,
      focalPoint: focal,
      rampCurve:
          active.rampCurveOverride?.toFlutterCurve() ??
          projectState.screenAnimationConfig.rampCurve,
    );
    final scale = matrix.storage[0];
    // Measure the VISIBLE camera, not the raw controller focal. getTransform
    // clamps the focal so the zoomed viewport stays inside the video; for an
    // edge cursor the spring focal chases the raw cursor past that clamp once
    // the enter ramp ends, so smearing by the raw focal paints a phantom
    // trail over an image that is actually pinned at the edge — the "flicker
    // as the zoom settles". Clamp to the same visible focal so post-clamp
    // motion contributes no smear. Identity for in-bounds focals.
    final visibleFocal =
        ZoomTransformer.clampFocalToBounds(focal, videoSize, scale);
    return SceneCameraSample(
      position: t,
      focal: visibleFocal,
      scale: scale,
    );
  }

  Future<ui.Image?> _applySceneMotionBlur(
    ui.Image sceneImage,
    SceneMotionBlurSignal signal,
  ) async {
    if (!signal.hasMotion || projectState.motionBlur <= 0) return null;

    final program = _sceneBlurProgram ??=
        await SceneMotionBlurShader.ensureLoaded();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      Rect.fromLTWH(0, 0, totalSize.width, totalSize.height),
    );
    paintSceneMotionBlur(
      canvas: canvas,
      image: sceneImage,
      program: program,
      size: totalSize,
      signal: signal,
      sampleCount: _sceneBlurSampleCount,
      speedCurveExp: _sceneBlurSpeedCurveExp,
      speedCurveRefPx: _sceneBlurSpeedCurveRefPx,
      devicePixelRatio: 1.0,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        totalSize.width.toInt(),
        totalSize.height.toInt(),
      );
    } finally {
      picture.dispose();
    }
  }

  void _paintWallpaper(Canvas canvas, {ui.Image? photo}) {
    final category = _frame.wallpaperCategory;
    if (category == null) return;
    final blur = _frame.backgroundBlur;
    final totalRect = Rect.fromLTWH(0, 0, totalSize.width, totalSize.height);

    void drawPhoto() {
      canvas.drawImageRect(
        photo!,
        Rect.fromLTWH(
          0,
          0,
          photo.width.toDouble(),
          photo.height.toDouble(),
        ),
        totalRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }

    void drawProcedural() {
      final decoration = wallpaperDecoration(category, _frame.wallpaperIndex);
      final boxPainter = decoration.createBoxPainter(() {});
      boxPainter.paint(
        canvas,
        Offset.zero,
        ImageConfiguration(size: totalSize),
      );
      boxPainter.dispose();
    }

    if (blur > 0) {
      // Mirror the preview's `ImageFiltered(ImageFilter.blur(...))`
      // wrapper around the wallpaper layer. saveLayer is required so
      // the filter applies to the wallpaper draw and nothing else.
      canvas.saveLayer(
        totalRect,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      );
      if (photo != null) {
        drawPhoto();
      } else {
        drawProcedural();
      }
      canvas.restore();
    } else if (photo != null) {
      drawPhoto();
    } else {
      drawProcedural();
    }
  }

  void _paintVideoFrame(Canvas canvas, ui.Image videoImage) {
    final dst = Rect.fromLTWH(
      _videoRect.left,
      _videoRect.top,
      videoSize.width,
      videoSize.height,
    );
    final src = Rect.fromLTWH(
      0,
      0,
      videoImage.width.toDouble(),
      videoImage.height.toDouble(),
    );
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(dst, Radius.circular(_frame.cornerRadius)),
    );
    canvas.drawImageRect(
      videoImage,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  /// Production preview ([`PlaybackScreen`]) hard-codes
  /// `CursorBlurMode.accumulation` for cursor motion blur. Export
  /// follows the same painter so the rendered MP4 is WYSIWYG with
  /// what the user edited (closes bug #3). The shader path
  /// ([`CursorOverlayPainter`]) is intentionally only kept for the
  /// playground's A/B compare screen.
  ///
  /// Exposure (150 ms) matches production preview's
  /// `accumulationExposureMs` so a slider drag and a re-export read
  /// the same trail length. Sample count (8) matches the preview's
  /// `accumulationSampleCount` default on [`PlaybackCanvas`].
  void _paintCursor(
    Canvas canvas, {
    required Duration position,
    required double intensity,
    required CursorState state,
  }) {
    final painter = AccumulationCursorPainter(
      cursorRecording: cursorRecording,
      position: position,
      videoSize: videoSize,
      // Match production preview (PlaybackScreen): 150 ms base
      // exposure scaled by the same effectiveCursorBlur the preview
      // uses. Zero blur → 0 ms → all N stamps land on the current
      // frame, so the painter degenerates to a single sharp sprite.
      exposureMs: 150.0 * intensity,
      sampleCount: 8,
      sizeMultiplier: projectState.cursorSize,
      style: projectState.cursorStyle,
      cursorState: state,
      // Export renders at the metadata's dpr; the painter sizes its
      // sprite buffer off this, not off MediaQuery. Live preview
      // passes the device's dpr from MediaQuery; the exporter has no
      // BuildContext, so 2.0 is the reasonable middle-of-the-road
      // default — sharper than 1.0, gentler than 3.0 on memory.
      devicePixelRatio: 2.0,
      // Tell the painter where the video lives inside the canvas so
      // stamps that land near the edge can bleed onto the wallpaper
      // padding (matches PlaybackCanvas, which sizes its cursor
      // layer to totalSize for the same reason).
      videoRect: Rect.fromLTWH(
        _videoRect.left,
        _videoRect.top,
        videoSize.width,
        videoSize.height,
      ),
      postProcess: projectState.cursorPostProcess,
      clickEffect: projectState.cursorClickEffect,
      clickSpring: projectState.clickSpring,
    );
    painter.paint(canvas, totalSize);
  }

  static Future<ui.Image> _bgraToImage(Uint8List bgra, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bgra,
      width,
      height,
      ui.PixelFormat.bgra8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }

  /// yuv420p (the H.264 pixel format the encoder uses) requires both
  /// dimensions to be even — without rounding, ffmpeg silently drops
  /// the last row/column or refuses to start.
  static Size _evenSize(Size s) {
    int even(double v) {
      final r = v.round();
      return r.isEven ? r : r + 1;
    }

    return Size(even(s.width).toDouble(), even(s.height).toDouble());
  }

  /// Position the video centered inside the (even-rounded) canvas, in
  /// canvas coordinates. Replaces the prior `_centeredPadding` helper now
  /// that [OutputCanvasResolver] returns a single canonical videoRect —
  /// the even-rounding pass can still add up to 1px slack per axis, and
  /// this redistributes it symmetrically so the video stays centered in
  /// the final encoded frame.
  static Rect _centeredVideoRect(Size canvas, Size videoSize) {
    final dx = (canvas.width - videoSize.width) / 2;
    final dy = (canvas.height - videoSize.height) / 2;
    return Rect.fromLTWH(dx, dy, videoSize.width, videoSize.height);
  }

  /// Releases retained GPU resources. m10: the wallpaper is rasterized once and
  /// cached for the whole export (~8-10MB at 1440p); without this it survives
  /// until GC finalizes the handle. Call when the compositor is done (see
  /// InProcessExportCompositor.dispose). Idempotent.
  void dispose() {
    _cachedWallpaperImage?.dispose();
    _cachedWallpaperImage = null;
    _cachedWallpaperKey = null;
  }
}
