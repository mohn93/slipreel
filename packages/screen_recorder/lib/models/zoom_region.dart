import 'package:flutter/material.dart';

/// Represents a zoom region with timing and transformation parameters
class ZoomRegion {
  final Rect rect;
  final Duration startTime;
  final Duration duration;
  final double zoomLevel;

  ZoomRegion({
    required Rect rect,
    required this.startTime,
    required this.duration,
    required double zoomLevel,
    Size? videoBounds,
  })  : assert(duration > Duration.zero, 'Duration must be positive'),
        rect = videoBounds != null ? _constrainRect(rect, videoBounds) : rect,
        zoomLevel = zoomLevel.clamp(1.0, 5.0);

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
    Size? videoBounds,
  }) {
    return ZoomRegion(
      rect: rect ?? this.rect,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      zoomLevel: zoomLevel ?? this.zoomLevel,
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
          zoomLevel == other.zoomLevel;

  @override
  int get hashCode =>
      rect.hashCode ^
      startTime.hashCode ^
      duration.hashCode ^
      zoomLevel.hashCode;
}
