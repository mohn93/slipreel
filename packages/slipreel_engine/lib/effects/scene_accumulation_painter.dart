import 'dart:ui' as ui;
import 'dart:ui' show BlendMode, Canvas, Color, FilterQuality, Paint, Rect, Size;

import 'package:flutter/rendering.dart' show CustomPainter, Matrix4;

/// True frame-accumulation motion blur for the scene composition, mirroring
/// the cursor's [AccumulationCursorPainter] approach.
///
/// The current frame's composition is captured once (via the RepaintBoundary
/// in [_buildSceneMotionBlurPass]), and this painter stamps that captured
/// image N times under N delta transforms — one per sub-frame timestamp
/// inside the exposure window. Each stamp lands at the position the body
/// would have had at that sub-frame, given the camera state there.
///
/// The captured image already has the *current* camera transform baked
/// into it. Each delta therefore expresses the camera difference between
/// the current frame and a sub-frame:
///
///     delta_i = A_i × A_current^{-1}
///
/// where `A_*` is the alignment-centered zoom matrix at that timestamp.
/// With `delta_0 = identity` the centre of the smear is the captured image
/// itself; trailing stamps fan out to where the body would have been at
/// earlier sub-frames. Where many stamps land on the same pixel the
/// accumulated alpha reaches 1; where only a few do, the result fades —
/// the natural motion-blur taper, without a single-velocity assumption.
class AccumulationScenePainter extends CustomPainter {
  AccumulationScenePainter({
    required this.image,
    required this.deltaTransforms,
  });

  final ui.Image image;
  final List<Matrix4> deltaTransforms;

  @override
  void paint(Canvas canvas, Size size) {
    if (deltaTransforms.isEmpty) return;
    if (size.width <= 0 || size.height <= 0) return;

    final alphaPerStamp = 1.0 / deltaTransforms.length;
    final srcRect = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Same trick as the cursor accumulation painter: isolate the stamps
    // onto an offscreen layer where BlendMode.plus can sum the per-stamp
    // alphas without leaking into the surrounding scene. The layer then
    // composites onto the scene with default srcOver.
    canvas.saveLayer(dstRect, Paint());

    final stampPaint = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: alphaPerStamp)
      ..blendMode = BlendMode.plus
      ..filterQuality = FilterQuality.medium;

    for (final delta in deltaTransforms) {
      canvas.save();
      canvas.transform(delta.storage);
      canvas.drawImageRect(image, srcRect, dstRect, stampPaint);
      canvas.restore();
    }

    // Clip the accumulated trail to the foreground's alpha. Some
    // stamps land at delta-transformed positions that extend beyond
    // the foreground footprint into the padding area — without this
    // mask, those trailing pixels would alpha-blend on top of the
    // (sticky) wallpaper below as foreground-coloured streaks.
    canvas.drawImageRect(
      image,
      srcRect,
      dstRect,
      Paint()..blendMode = BlendMode.dstIn,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AccumulationScenePainter old) => true;
}
