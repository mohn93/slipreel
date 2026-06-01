import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/output_aspect.dart';

/// Result of [OutputCanvasResolver.resolve]: the final canvas
/// dimensions and the rect inside that canvas where the source video
/// should be drawn.
class ResolvedCanvas {
  const ResolvedCanvas({required this.canvasSize, required this.videoRect});

  /// Total output canvas size in pixels (wallpaper + padding + video).
  final Size canvasSize;

  /// Where the source video sits inside [canvasSize], in canvas
  /// coordinates. The video is aspect-preserved — never stretched.
  final Rect videoRect;
}

/// Single source of truth for output-canvas dimensions, used by both
/// the editor preview ([PlaybackCanvas]) and the export pipeline
/// ([FrameCompositor]).
///
/// Composes three inputs into a canvas + video rect:
///   • [videoSize] — the raw source video resolution.
///   • [padding] — uniform inset around the video. Pass
///     `WindowFrame.padding` directly; the resolver treats every side
///     as a literal pixel value (no aspect-scaling).
///   • [aspect] — the target output aspect. [OutputAspect.auto] doesn't
///     impose a target ratio — the canvas matches the padded inner
///     region's aspect (equal to the source video's aspect when
///     padding is zero).
///
/// Letterbox-fit only — when the chosen aspect doesn't match the
/// padded inner region, the canvas GROWS along the under-sized axis to
/// reach the target ratio. The video itself never crops or stretches.
class OutputCanvasResolver {
  const OutputCanvasResolver._();

  static ResolvedCanvas resolve({
    required Size videoSize,
    required EdgeInsets padding,
    required OutputAspect aspect,
  }) {
    if (videoSize.width <= 0 || videoSize.height <= 0) {
      return const ResolvedCanvas(
        canvasSize: Size.zero,
        videoRect: Rect.zero,
      );
    }

    final paddedWidth = videoSize.width + padding.horizontal;
    final paddedHeight = videoSize.height + padding.vertical;
    final innerAspect = paddedWidth / paddedHeight;

    final targetAspect = aspect.ratio ?? innerAspect;

    final double canvasWidth;
    final double canvasHeight;
    if (targetAspect > innerAspect) {
      canvasWidth = paddedHeight * targetAspect;
      canvasHeight = paddedHeight;
    } else if (targetAspect < innerAspect) {
      canvasWidth = paddedWidth;
      canvasHeight = paddedWidth / targetAspect;
    } else {
      canvasWidth = paddedWidth;
      canvasHeight = paddedHeight;
    }

    final canvasSize = Size(canvasWidth, canvasHeight);

    final innerDx = (canvasWidth - paddedWidth) / 2;
    final innerDy = (canvasHeight - paddedHeight) / 2;
    final videoRect = Rect.fromLTWH(
      innerDx + padding.left,
      innerDy + padding.top,
      videoSize.width,
      videoSize.height,
    );

    return ResolvedCanvas(canvasSize: canvasSize, videoRect: videoRect);
  }
}
