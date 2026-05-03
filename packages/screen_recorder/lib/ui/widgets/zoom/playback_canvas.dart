import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/rendering/frame_painter.dart';
import 'package:screen_recorder/rendering/wallpaper.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/cursor_overlay_painter.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/cursor_motion_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_debug_painter.dart';

/// The composed playback canvas: wallpaper layer, framed video,
/// cursor overlay, optional debug HUD, all wrapped in a zoom Transform
/// that pushes the entire composition together when a zoom region is
/// active. Sized via AspectRatio + FittedBox so the canvas scales to
/// fit its parent without distorting the source aspect ratio.
///
/// Owns the three per-frame controllers — [ZoomTransformer],
/// [ZoomFocalController], [CursorMotionController] — so the parent
/// screen doesn't need to manage their lifecycles or expose their
/// state. Reads its inputs purely as widget props; settings flow in
/// through [frameSettings] / [screenAnimationConfig] /
/// [cursorAnimationConfig] etc., and changes there rebuild the canvas
/// without rebuilding the surrounding shell.
class PlaybackCanvas extends StatefulWidget {
  const PlaybackCanvas({
    super.key,
    required this.controller,
    required this.smoothPlayhead,
    required this.frameSettings,
    required this.metadata,
    required this.cursorRecording,
    required this.hideCursorOverlay,
    required this.cursorSize,
    required this.cursorStyle,
    required this.cursorClickEffect,
    required this.showZoomDebug,
    required this.zoomRegions,
    required this.screenAnimationConfig,
    required this.cursorAnimationConfig,
  });

  final VideoPlayerController controller;
  final SmoothPlayheadController? smoothPlayhead;
  final FrameSettingsProvider frameSettings;
  final RecordingMetadata? metadata;
  final CursorRecording cursorRecording;
  final bool hideCursorOverlay;
  final double cursorSize;
  final CursorStyle cursorStyle;
  final CursorClickEffect cursorClickEffect;
  final bool showZoomDebug;
  final List<ZoomRegion> zoomRegions;
  final ScreenAnimationConfig screenAnimationConfig;
  final CursorAnimationConfig cursorAnimationConfig;

  @override
  State<PlaybackCanvas> createState() => _PlaybackCanvasState();
}

class _PlaybackCanvasState extends State<PlaybackCanvas> {
  final ZoomTransformer _zoomTransformer = ZoomTransformer();
  // Cursor-driven zoom focal smoothing. State (active-zoom tracking,
  // last smoothed offset) lives in the controller so it can be unit-
  // tested without a widget tree.
  final ZoomFocalController _zoomFocalController = ZoomFocalController();
  // Smooths the synthetic cursor's on-screen position toward the
  // recorded path each frame, driven by cursorAnimationConfig.
  final CursorMotionController _cursorMotionController =
      CursorMotionController();

  @override
  Widget build(BuildContext context) {
    final videoSize = widget.controller.value.size;
    final currentFrame = widget.frameSettings.currentFrame;
    final totalSize = FramePainter.calculateTotalSize(
      frame: currentFrame,
      videoSize: videoSize,
    );
    // Effective padding has X scaled by the video aspect so layout
    // matches the canvas computed by calculateTotalSize.
    final effPadding = FramePainter.effectivePadding(
      currentFrame.padding,
      videoSize,
    );

    // Single AnimatedBuilder rebuilt per frame: drives the cursor
    // overlay (needs current playhead) AND the zoom Transform. The
    // VideoPlayer is held as `child` so its widget isn't reconstructed
    // each frame even though the surrounding Stack is.
    //
    // Zoom Transform wraps the ENTIRE composition (wallpaper + frame
    // + video + cursor + dev HUD) so when zoom kicks in everything
    // pushes in together rather than only the video pixels scaling
    // while the wallpaper stays put. ClipRect on the outside keeps
    // the scaled-up tail inside the frame so it doesn't leak across
    // the editor backdrop.
    Widget framedVideo = SizedBox(
      width: totalSize.width,
      height: totalSize.height,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: Listenable.merge([widget.controller, widget.smoothPlayhead]),
          child: VideoPlayer(widget.controller),
          builder: (context, videoPlayer) {
            final pos = widget.smoothPlayhead?.position ??
                widget.controller.value.position;
            final showCursor = widget.metadata?.isPureSource == true &&
                widget.cursorRecording.count > 0 &&
                !widget.hideCursorOverlay;

            final motion = showCursor
                ? _cursorMotionController.update(
                    position: pos,
                    cursorRecording: widget.cursorRecording,
                    config: widget.cursorAnimationConfig,
                    fps: widget.metadata?.fps ?? 60,
                  )
                : null;

            final composition = Stack(
              children: [
                if (currentFrame.wallpaperCategory != null)
                  Positioned.fill(
                    child: _wallpaperLayer(
                      category: currentFrame.wallpaperCategory!,
                      index: currentFrame.wallpaperIndex,
                      blur: currentFrame.backgroundBlur,
                    ),
                  ),
                CustomPaint(
                  size: totalSize,
                  painter: FramePainter(
                    frame: currentFrame,
                    videoSize: videoSize,
                  ),
                ),
                Positioned(
                  left: effPadding.left,
                  top: effPadding.top,
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(currentFrame.cornerRadius),
                    child: SizedBox(
                      width: videoSize.width,
                      height: videoSize.height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          videoPlayer!,
                          if (motion != null)
                            CustomPaint(
                              painter: CursorOverlayPainter(
                                cursorRecording: widget.cursorRecording,
                                position: pos,
                                screenPos: motion.screenPos,
                                videoSize: videoSize,
                                screenSize: videoSize,
                                sizeMultiplier: widget.cursorSize,
                                style: widget.cursorStyle,
                                clickEffect: widget.cursorClickEffect,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
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
                            smoothedFocal:
                                _zoomFocalController.smoothedFocal,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );

            final focalUpdate = _zoomFocalController.update(
              position: pos,
              zoomRegions: widget.zoomRegions,
              cursorRecording: widget.cursorRecording,
              smoothing: _focalSmoothingFor(widget.cursorAnimationConfig),
            );
            if (focalUpdate == null) return composition;

            final activeZoom = focalUpdate.zoom;
            final focalForFrame = focalUpdate.focal;

            // Smoothly interpolate the rendered zoom level when the
            // user changes it via the badge — otherwise stepping the
            // level produces a visual snap.
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(end: activeZoom.zoomLevel),
              duration: widget.screenAnimationConfig.badgeDuration,
              curve: widget.screenAnimationConfig.badgeCurve,
              child: composition,
              builder: (context, animatedZoom, transformChild) {
                final tweenedRegion =
                    activeZoom.copyWith(zoomLevel: animatedZoom);
                final transform = _zoomTransformer.getTransform(
                  position: pos,
                  zoomRegion: tweenedRegion,
                  videoSize: videoSize,
                  focalPoint: focalForFrame,
                  rampCurve: activeZoom.rampCurveOverride?.toFlutterCurve()
                      ?? widget.screenAnimationConfig.rampCurve,
                );
                return Transform(
                  transform: transform,
                  alignment: Alignment.center,
                  child: transformChild,
                );
              },
            );
          },
        ),
      ),
    );

    return AspectRatio(
      aspectRatio: totalSize.width / totalSize.height,
      child: FittedBox(
        fit: BoxFit.contain,
        child: framedVideo,
      ),
    );
  }

  Widget _wallpaperLayer({
    required String category,
    required int index,
    required double blur,
  }) {
    final fill = Container(
      decoration: wallpaperDecoration(category, index),
    );
    if (blur <= 0) return fill;
    // ClipRect prevents the gaussian tail from leaking outside the
    // frame's totalSize. ImageFiltered does a saveLayer internally,
    // which is why we skip it altogether at sigma 0.
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: fill,
      ),
    );
  }

  /// Map the cursor config's FIR window onto the legacy lerp factor used
  /// by [ZoomFocalController]. The focal smoothing intentionally only
  /// reads the window length — not the custom curve's shape — because
  /// [ZoomFocalController] is a separate IIR low-pass filter for the
  /// zoom-camera focal point, not the cursor itself. As a result, the
  /// rendered cursor and the zoom focal point can have visibly
  /// different lag profiles when a Custom cursor config is in use.
  /// This is by design: focal lag is a UX-stability concern (not the
  /// expressive choice the user is making with a custom curve).
  double _focalSmoothingFor(CursorAnimationConfig cfg) {
    final ms = cfg.window.inMilliseconds;
    if (ms <= 0)   return 1.00;   // None → snap
    if (ms <= 90)  return 0.40;   // Rapid
    if (ms <= 250) return 0.18;   // Medium
    return 0.08;                  // Smooth or longer custom windows
  }
}
