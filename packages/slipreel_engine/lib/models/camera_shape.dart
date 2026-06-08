/// The crop frame of the camera bubble. Global (not per-region) per the
/// brainstorming decision: every region shares one shape/roundness/style;
/// only position/size/visibility vary per region.
enum CameraShape {
  square,
  horizontal,
  vertical,
  original,
  circle;

  /// Pixel width:height the bubble box should hold for this shape. The
  /// region stores only placement + width; the renderer derives the box
  /// height from this aspect, so changing the shape re-aspects every
  /// region with no data migration.
  ///
  /// [originalAspect] is the source camera's width/height, used only by
  /// [CameraShape.original]; a non-finite or non-positive value falls back
  /// to 1.0 so a missing sidecar never yields a degenerate box.
  double pixelAspect(double originalAspect) {
    switch (this) {
      case CameraShape.square:
      case CameraShape.circle:
        return 1.0;
      case CameraShape.horizontal:
        return 16 / 9;
      case CameraShape.vertical:
        return 9 / 16;
      case CameraShape.original:
        return (originalAspect.isFinite && originalAspect > 0)
            ? originalAspect
            : 1.0;
    }
  }

  /// Circle is always fully round, so the roundness control greys out.
  bool get isRound => this == CameraShape.circle;
}
