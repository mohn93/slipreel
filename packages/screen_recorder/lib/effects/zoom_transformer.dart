import 'package:flutter/material.dart';
import 'package:screen_recorder/models/zoom_region.dart';

/// Calculates transformation matrices for zoom effects
class ZoomTransformer {
  /// Get transformation matrix for given position and zoom region
  Matrix4 getTransform({
    required Duration position,
    required ZoomRegion zoomRegion,
    required Size videoSize,
  }) {
    // Return identity if zoom is not active
    if (!zoomRegion.isActive(position)) {
      return Matrix4.identity();
    }

    // Get progress within zoom region (0.0 to 1.0)
    final rawProgress = zoomRegion.getProgress(position);

    // Apply ease-in-out curve for smooth animation
    // Zoom in during first half, zoom out during second half
    final curvedProgress = _easeInOutCurve(rawProgress);

    // Calculate zoom factor (1.0 to zoomLevel and back to 1.0)
    final zoomFactor = _calculateZoomFactor(
      curvedProgress,
      zoomRegion.zoomLevel,
    );

    // Calculate center of zoom region
    final zoomCenter = zoomRegion.rect.center;

    // Calculate video center
    final videoCenter = Offset(videoSize.width / 2, videoSize.height / 2);

    // Calculate translation to center zoom region
    final translation = _calculateTranslation(
      zoomCenter: zoomCenter,
      videoCenter: videoCenter,
      zoomFactor: zoomFactor,
    );

    // Build transformation matrix
    final matrix = Matrix4.identity()
      ..translate(translation.dx, translation.dy)
      ..scale(zoomFactor, zoomFactor, 1.0)
      ..translate(-translation.dx, -translation.dy);

    return matrix;
  }

  /// Apply ease-in-out curve
  double _easeInOutCurve(double t) {
    if (t < 0.5) {
      return 2 * t * t;
    } else {
      return 1 - 2 * (1 - t) * (1 - t);
    }
  }

  /// Calculate zoom factor for given progress
  /// Zooms in during first half, zooms out during second half
  double _calculateZoomFactor(double progress, double maxZoom) {
    // Use sine wave for smooth zoom in/out
    // Progress 0.0 -> 1.0, sine gives smooth curve
    final sineProgress = (1 - (progress * 2 - 1).abs());
    return 1.0 + (maxZoom - 1.0) * sineProgress;
  }

  /// Calculate translation to center zoom on target region
  Offset _calculateTranslation({
    required Offset zoomCenter,
    required Offset videoCenter,
    required double zoomFactor,
  }) {
    // Calculate offset from video center to zoom center
    final offset = zoomCenter - videoCenter;

    // Scale offset by zoom factor to keep region centered
    return Offset(
      videoCenter.dx - offset.dx * zoomFactor,
      videoCenter.dy - offset.dy * zoomFactor,
    );
  }
}
