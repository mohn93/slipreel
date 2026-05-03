import 'package:flutter/material.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';

/// How the zoom camera tracks the cursor while a region is active.
///
/// All three modes feed the same duration+curve catch-up tween — they
/// only differ in what target the camera is aimed at each frame.
enum FollowMode {
  /// Default. The camera holds steady while the cursor sits inside a
  /// centered deadzone box; once the cursor leaves the deadzone the
  /// camera tweens out to it. After the tween completes, a new
  /// deadzone re-engages around the new focal.
  bounded,

  /// The camera tweens toward the cursor every frame. Smoothest
  /// real-time tracking; no "rest zone".
  centered,

  /// The camera aims at the *median* cursor position over a rolling
  /// time window — i.e., the spot where the cursor has been
  /// spending the most time recently. Brief excursions don't move
  /// the camera; sustained dwell in a new region does, gradually.
  predictive,
}

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
  static const Duration _defaultFollow = Duration(milliseconds: 400);
  static const Duration _defaultPredictiveWindow =
      Duration(milliseconds: 1500);

  final Rect rect;
  final Duration startTime;
  final Duration duration;
  final double zoomLevel;
  final Duration enterDuration;
  final Duration exitDuration;
  final CubicBezierCurve? rampCurveOverride;

  /// Whether the zoom focal point follows the recorded cursor.
  ///
  /// When `false`, the focal stays pinned to [rect.center] for the
  /// entire region — useful for "show this UI element" zooms where
  /// you don't want the camera moving with the user's mouse.
  final bool followCursor;

  /// How the camera follows the cursor — see [FollowMode]. Default
  /// is [FollowMode.bounded].
  final FollowMode followMode;

  /// Edge length of the deadzone as a fraction of the *visible
  /// viewport* (the region of source video framed by the current
  /// zoom). 0.3 = a centered box covering 30% of the viewport on
  /// each axis. Only consulted when [followMode] is
  /// [FollowMode.bounded].
  final double deadzoneRatio;

  /// Length of the rolling window over which the predictive median
  /// is computed. Only consulted when [followMode] is
  /// [FollowMode.predictive]. Longer windows feel more "settled"
  /// (camera ignores brief activity); shorter windows feel more
  /// responsive.
  final Duration predictiveWindow;

  /// How long the focal takes to catch up to a new target (cursor
  /// after a deadzone exit, or rect.center when [followCursor] is
  /// toggled off). Zero or negative ⇒ snap.
  final Duration followDuration;

  /// Optional curve shaping the catch-up tween. `null` ⇒ the system
  /// default (`Curves.easeOutCubic`).
  final CubicBezierCurve? followCurve;

  ZoomRegion({
    required Rect rect,
    required this.startTime,
    required this.duration,
    required double zoomLevel,
    Duration? enterDuration,
    Duration? exitDuration,
    Size? videoBounds,
    this.rampCurveOverride,
    this.followCursor = true,
    this.followMode = FollowMode.bounded,
    double deadzoneRatio = 0.3,
    Duration? followDuration,
    this.followCurve,
    Duration? predictiveWindow,
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
                : (exitDuration ?? _defaultExit),
        deadzoneRatio = deadzoneRatio.clamp(0.0, 1.0),
        followDuration = (followDuration ?? _defaultFollow).isNegative
            ? Duration.zero
            : (followDuration ?? _defaultFollow),
        predictiveWindow =
            (predictiveWindow ?? _defaultPredictiveWindow).isNegative
                ? _defaultPredictiveWindow
                : (predictiveWindow ?? _defaultPredictiveWindow);

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

  /// Create copy with updated values.
  ///
  /// To clear an existing [rampCurveOverride], pass
  /// `clearRampCurveOverride: true`. Passing `rampCurveOverride: null`
  /// (the default) leaves the existing override unchanged so callers can
  /// distinguish "leave as-is" from "clear".
  ZoomRegion copyWith({
    Rect? rect,
    Duration? startTime,
    Duration? duration,
    double? zoomLevel,
    Duration? enterDuration,
    Duration? exitDuration,
    Size? videoBounds,
    CubicBezierCurve? rampCurveOverride,
    bool clearRampCurveOverride = false,
    bool? followCursor,
    FollowMode? followMode,
    double? deadzoneRatio,
    Duration? followDuration,
    CubicBezierCurve? followCurve,
    bool clearFollowCurve = false,
    Duration? predictiveWindow,
  }) {
    return ZoomRegion(
      rect: rect ?? this.rect,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      zoomLevel: zoomLevel ?? this.zoomLevel,
      enterDuration: enterDuration ?? this.enterDuration,
      exitDuration: exitDuration ?? this.exitDuration,
      videoBounds: videoBounds,
      rampCurveOverride: clearRampCurveOverride
          ? null
          : (rampCurveOverride ?? this.rampCurveOverride),
      followCursor: followCursor ?? this.followCursor,
      followMode: followMode ?? this.followMode,
      deadzoneRatio: deadzoneRatio ?? this.deadzoneRatio,
      followDuration: followDuration ?? this.followDuration,
      followCurve:
          clearFollowCurve ? null : (followCurve ?? this.followCurve),
      predictiveWindow: predictiveWindow ?? this.predictiveWindow,
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
          exitDuration == other.exitDuration &&
          rampCurveOverride == other.rampCurveOverride &&
          followCursor == other.followCursor &&
          followMode == other.followMode &&
          deadzoneRatio == other.deadzoneRatio &&
          followDuration == other.followDuration &&
          followCurve == other.followCurve &&
          predictiveWindow == other.predictiveWindow;

  @override
  int get hashCode => Object.hash(
        rect,
        startTime,
        duration,
        zoomLevel,
        enterDuration,
        exitDuration,
        rampCurveOverride,
        followCursor,
        followMode,
        deadzoneRatio,
        followDuration,
        followCurve,
        predictiveWindow,
      );
}
