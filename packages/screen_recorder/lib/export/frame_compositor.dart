import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder/rendering/frame_painter.dart';
import 'package:screen_recorder/rendering/wallpaper.dart';
import 'package:screen_recorder/state/editor_project_state.dart';
import 'package:screen_recorder/ui/widgets/cursor_overlay_painter.dart';
import 'package:screen_recorder/ui/widgets/zoom/cursor_motion_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';

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
  })  : _framePainter = FramePainter(
          frame: projectState.windowFrame,
          videoSize: videoSize,
        ),
        totalSize = _evenSize(FramePainter.calculateTotalSize(
          frame: projectState.windowFrame,
          videoSize: videoSize,
        )),
        _effectivePadding = FramePainter.effectivePadding(
          projectState.windowFrame.padding,
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

  /// Output canvas size — the framed totalSize, rounded to even
  /// pixels (yuv420p subsampling requires it).
  final Size totalSize;

  final FramePainter _framePainter;
  final EdgeInsets _effectivePadding;

  final ZoomFocalController _focalController = ZoomFocalController();
  final CursorMotionController _motionController = CursorMotionController();

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
      // Cursor motion shares one source of truth with the preview:
      // the FIR-smoothed offset feeds both the sprite's drawn position
      // and the zoom focal target so they can't drift apart.
      final motion = _hasCursorData
          ? _motionController.update(
              position: position,
              cursorRecording: cursorRecording,
              config: projectState.cursorAnimationConfig,
              fps: fps,
            )
          : null;

      // Predictive follow gets a different cursor source — the
      // rolling median over the recording — so it tracks the dwell
      // location, not the instantaneous (smoothed) cursor.
      final activeZoom = _activeZoomAt(position);
      final cursorForFocal = activeZoom?.followMode == FollowMode.predictive
          ? medianCursorOver(
              recording: cursorRecording,
              t: position,
              window: activeZoom!.predictiveWindow,
            )
          : motion?.screenPos;

      final focalUpdate = _focalController.update(
        position: position,
        zoomRegions: projectState.zoomRegions,
        cursor: cursorForFocal,
        videoSize: videoSize,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder,
          Rect.fromLTWH(0, 0, totalSize.width, totalSize.height));

      // Apply the zoom Transform around totalSize/2, matching the
      // preview's `Transform(alignment: Alignment.center, ...)`.
      // The matrix's translation is built against videoSize/2; the
      // arithmetic happens to land the focal at the alignment origin
      // because effPadding centers the video inside totalSize, so
      // `effPad.left - totalSize.width/2 = -videoSize.width/2`.
      if (focalUpdate != null) {
        final ramp = focalUpdate.zoom.rampCurveOverride?.toFlutterCurve() ??
            projectState.screenAnimationConfig.rampCurve;
        final transform = ZoomTransformer().getTransform(
          position: position,
          zoomRegion: focalUpdate.zoom,
          videoSize: videoSize,
          focalPoint: focalUpdate.focal,
          rampCurve: ramp,
        );
        canvas.translate(totalSize.width / 2, totalSize.height / 2);
        canvas.transform(transform.storage);
        canvas.translate(-totalSize.width / 2, -totalSize.height / 2);
      }

      _paintWallpaper(canvas);
      _framePainter.paint(canvas, totalSize);
      _paintVideoFrame(canvas, videoImage);
      if (motion != null && !projectState.hideCursorOverlay) {
        _paintCursor(canvas, position: position, screenPos: motion.screenPos);
      }

      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(
          totalSize.width.toInt(),
          totalSize.height.toInt(),
        );
        try {
          final byteData =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          if (byteData == null) {
            throw StateError('toByteData returned null at $position');
          }
          // Defensive copy — the underlying buffer is owned by the
          // ui.Image and freed when we dispose it.
          return Uint8List.fromList(byteData.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      videoImage.dispose();
    }
  }

  // --- internals --------------------------------------------------------

  void _paintWallpaper(Canvas canvas) {
    final category = _frame.wallpaperCategory;
    if (category == null) return;
    final decoration = wallpaperDecoration(category, _frame.wallpaperIndex);
    final boxPainter = decoration.createBoxPainter(() {});
    final imageConfig = ImageConfiguration(size: totalSize);
    final blur = _frame.backgroundBlur;
    if (blur > 0) {
      // Mirror the preview's `ImageFiltered(ImageFilter.blur(...))`
      // wrapper around the wallpaper layer. saveLayer is required so
      // the filter applies to the wallpaper draw and nothing else.
      final layerRect = Rect.fromLTWH(0, 0, totalSize.width, totalSize.height);
      canvas.saveLayer(
        layerRect,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      );
      boxPainter.paint(canvas, Offset.zero, imageConfig);
      canvas.restore();
    } else {
      boxPainter.paint(canvas, Offset.zero, imageConfig);
    }
    boxPainter.dispose();
  }

  void _paintVideoFrame(Canvas canvas, ui.Image videoImage) {
    final dst = Rect.fromLTWH(
      _effectivePadding.left,
      _effectivePadding.top,
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
    canvas.clipRRect(RRect.fromRectAndRadius(
      dst,
      Radius.circular(_frame.cornerRadius),
    ));
    canvas.drawImageRect(
      videoImage,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  void _paintCursor(
    Canvas canvas, {
    required Duration position,
    required Offset screenPos,
  }) {
    canvas.save();
    canvas.translate(_effectivePadding.left, _effectivePadding.top);
    final painter = CursorOverlayPainter(
      cursorRecording: cursorRecording,
      position: position,
      screenPos: screenPos,
      videoSize: videoSize,
      screenSize: videoSize,
      sizeMultiplier: projectState.cursorSize,
      style: projectState.cursorStyle,
      clickEffect: projectState.cursorClickEffect,
    );
    painter.paint(canvas, videoSize);
    canvas.restore();
  }

  ZoomRegion? _activeZoomAt(Duration t) {
    for (final z in projectState.zoomRegions) {
      if (z.isActive(t)) return z;
    }
    return null;
  }

  static Future<ui.Image> _bgraToImage(
    Uint8List bgra,
    int width,
    int height,
  ) {
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
}
