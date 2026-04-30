import 'package:flutter/material.dart';

/// Represents a zoom region with timing and transformation parameters.
///
/// A zoom region runs in three phases across its [duration]:
///  1. Enter ramp from 1× → [zoomLevel] over [enterDuration].
///  2. Hold at [zoomLevel] for the middle.
///  3. Exit ramp from [zoomLevel] → 1× over [exitDuration].
///
/// If [enterDuration] + [exitDuration] would consume the entire region
/// (or more), they are scaled down proportionally so the region still has
/// a consistent shape; the hold becomes zero-length in that case.
class ZoomRegion {
  static const Duration _defaultEnter = Duration(milliseconds: 500);
  static const Duration _defaultExit = Duration(milliseconds: 500);

  final Rect rect;
  final Duration startTime;
  final Duration duration;
  final double zoomLevel;
  final Duration enterDuration;
  final Duration exitDuration;

  ZoomRegion({
    required Rect rect,
    required this.startTime,
    required this.duration,
    required double zoomLevel,
    Duration? enterDuration,
    Duration? exitDuration,
    Size? videoBounds,
  })  : assert(duration > Duration.zero, 'Duration must be positive'),
        rect = videoBounds != null ? _constrainRect(rect, videoBounds) : rect,
        zoomLevel = zoomLevel.clamp(1.0, 5.0),
        enterDuration =
            (enterDuration ?? _defaultEnter).isNegative
                ? Duration.zero
                : (enterDuration ?? _defaultEnter),
        exitDuration =
            (exitDuration ?? _defaultExit).isNegative
                ? Duration.zero
                : (exitDuration ?? _defaultExit);

  /// End time of zoom effect
  Duration get endTime => startTime + duration;

  /// Check if position is within zoom region
  bool isActive(Duration position) {
    return position >= startTime && position <= endTime;
  }

  /// Get progress within zoom region (0.0 to 1.0)
  double getProgress(Duration position) {
    if (position < startTime) return 0.0;
    if (position > endTime) return 1.0;

    final elapsed = position - startTime;
    return (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  }

  /// Create copy with updated values
  ZoomRegion copyWith({
    Rect? rect,
    Duration? startTime,
    Duration? duration,
    double? zoomLevel,
    Duration? enterDuration,
    Duration? exitDuration,
    Size? videoBounds,
  }) {
    return ZoomRegion(
      rect: rect ?? this.rect,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      zoomLevel: zoomLevel ?? this.zoomLevel,
      enterDuration: enterDuration ?? this.enterDuration,
      exitDuration: exitDuration ?? this.exitDuration,
      videoBounds: videoBounds,
    );
  }

  static Rect _constrainRect(Rect rect, Size bounds) {
    final left = rect.left.clamp(0.0, bounds.width);
    final top = rect.top.clamp(0.0, bounds.height);
    final right = rect.right.clamp(0.0, bounds.width);
    final bottom = rect.bottom.clamp(0.0, bounds.height);

    return Rect.fromLTRB(left, top, right, bottom);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomRegion &&
          runtimeType == other.runtimeType &&
          rect == other.rect &&
          startTime == other.startTime &&
          duration == other.duration &&
          zoomLevel == other.zoomLevel &&
          enterDuration == other.enterDuration &&
          exitDuration == other.exitDuration;

  @override
  int get hashCode => Object.hash(
        rect,
        startTime,
        duration,
        zoomLevel,
        enterDuration,
        exitDuration,
      );
}
