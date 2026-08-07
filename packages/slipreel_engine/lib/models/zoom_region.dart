import 'dart:ui' show Rect, Size;

import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';

import 'zoom_movement.dart';

/// How the zoom camera tracks the cursor while a region is active.
///
/// All modes feed the same critically-damped catch-up spring (see
/// [ZoomFocalController]) — they only differ in what target the camera is
/// aimed at each frame. [followDuration] is the spring's settle time; it also
/// sets how much the spring smooths (rounds) the cursor's path into a curve.
enum FollowMode {
  /// Legacy reactive deadzone follow. Preserved so existing projects keep
  /// byte-for-byte camera trajectories until the user explicitly upgrades.
  bounded,

  /// The camera springs toward the cursor every frame. Smoothest
  /// real-time tracking; no "rest zone".
  centered,

  /// Legacy persisted name for [smart]. Kept so existing predictive projects
  /// round-trip unchanged and source integrations remain valid.
  predictive,

  /// User-facing Smart follow. Holds inside a deadzone, then uses speed-faded
  /// anticipation to begin a smooth chase before deliberate motion reaches
  /// the frame edge.
  smart;

  /// Whether this value uses speed-aware anticipation.
  bool get isSmart =>
      this == FollowMode.smart || this == FollowMode.predictive;

  /// Whether this value uses a deadzone gate.
  bool get usesDeadzone => this != FollowMode.centered;

  /// Runtime/UI identity. Predictive is a persisted compatibility alias for
  /// Smart; bounded stays distinct because changing it would alter old renders.
  FollowMode get canonical =>
      this == FollowMode.predictive ? FollowMode.smart : this;
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
  // Catch-up spring settle time (also the amount the spring smooths the
  // cursor's path into a curve). History: 400 ms originally; 700 ms to stop
  // fast flicks reading as a jolt; 850 ms because below ~750 ms the camera
  // hugs the raw (straight) cursor path and the follow reads as rigidly
  // linear — 850 ms rounds the corners into a smooth curve without the
  // camera visibly "swimming" behind the cursor.
  static const Duration _defaultFollow = Duration(milliseconds: 850);
  // Smart look-ahead lead time: how far ahead the Smart follow strategy aims
  // (cursor + velocity·leadTime). 150 ms leads enough to cancel
  // the spring's settle lag without overshooting on click landings (velocity
  // ≈ 0 at rest ⇒ no lead). Clamped to [80, 250] ms.
  static const Duration _defaultLeadTime = Duration(milliseconds: 150);
  static const Duration _minLeadTime = Duration(milliseconds: 80);
  static const Duration _maxLeadTime = Duration(milliseconds: 250);

  static int _idCounter = 0;
  static int _nextId() => _idCounter++;

  /// Transient per-session identity: unique per constructed region,
  /// preserved through [copyWith] so a region keeps its identity across
  /// edits (drag, resize, level change). The timeline lanes key their pill
  /// widgets on it — index-based keys made deleting a region re-bind every
  /// later pill element to its neighbour's data, and the pills' implicit
  /// position tweens then slid the survivors across the lane.
  ///
  /// Deliberately EXCLUDED from [==]/[hashCode] (identity, not value) and
  /// from JSON (regions get fresh ids on load).
  final int id;

  final Rect rect;
  final Duration startTime;
  final Duration duration;
  final double zoomLevel;
  final Duration enterDuration;
  final Duration exitDuration;
  final CubicBezierCurve? rampCurveOverride;

  /// Debug/tuning override for the MANUAL (followCursor:false) enter-pan
  /// back-load exponent (see [MotionTuning.manualEntryPanBackload]). `null`
  /// ⇒ fall back to the session default. Stored per-region because the
  /// ideal exponent depends on this region's [zoomLevel]; it exists so the
  /// sweet spot can be tuned at several zoom levels to derive
  /// `backload = f(zoomLevel)`. No effect when [followCursor] is true.
  final double? manualPanBackload;

  /// Whether the zoom focal point follows the recorded cursor.
  ///
  /// When `false`, the focal stays pinned to [rect.center] for the
  /// entire region — useful for "show this UI element" zooms where
  /// you don't want the camera moving with the user's mouse. The render
  /// magnifies in place about that point (see [ZoomFraming.centerOffsetInPlace]).
  ///
  /// For a manual placement authored against the composed canvas (padding /
  /// wallpaper / device bezel), [rect.center] MAY fall OUTSIDE `[0, videoSize]`
  /// — i.e. the focal can sit in the padding. Such placements are constructed
  /// with `videoBounds: null` so [rect] is not clamped back onto the screen;
  /// the placement picker keeps the resulting viewport inside the canvas.
  final bool followCursor;

  /// How the camera follows the cursor — see [FollowMode]. The user-facing
  /// choices are [FollowMode.smart] and [FollowMode.centered]. Existing
  /// [FollowMode.bounded] projects retain a conditional legacy option.
  final FollowMode followMode;

  /// Edge length of the deadzone as a fraction of the *visible
  /// viewport* (the region of source video framed by the current
  /// zoom). 0.3 = a centered box covering 30% of the viewport on
  /// each axis. Consulted by every deadzone follow mode.
  final double deadzoneRatio;

  /// Smart look-ahead lead time: how far ahead Smart follow aims along the
  /// cursor's velocity. Clamped to [80, 250] ms; default 150 ms.
  /// (Field name retained for JSON back-compat — see `predictiveWindowMicros`.)
  final Duration predictiveWindow;

  /// How long the focal takes to catch up to a new target.
  ///
  /// Interpreted by [ZoomFocalController] as the critically-damped
  /// spring's *settle time*: the camera is ≈95% of the way to a new
  /// target after one [followDuration], fully arrived after ≈3×.
  /// Zero or negative ⇒ snap.
  final Duration followDuration;

  /// 3D perspective tilt for this zoom. [Tilt3D.flat] (the default) is a 2D
  /// zoom — byte-identical to legacy behavior. Subtle/dramatic/manual add a
  /// perspective tilt to the content panel (see [ZoomTransformer.getTransform]).
  final Tilt3D tilt;

  /// Camera movement (push-in / sweep / drift) layered on top of the
  /// settled zoom hold. [ZoomMovement.none] (the default) is a static
  /// hold — today's behavior, unchanged.
  final ZoomMovement movement;

  ZoomRegion({
    required Rect rect,
    required this.startTime,
    required this.duration,
    required double zoomLevel,
    Duration? enterDuration,
    Duration? exitDuration,
    Size? videoBounds,
    this.rampCurveOverride,
    this.manualPanBackload,
    this.followCursor = true,
    this.followMode = FollowMode.smart,
    double deadzoneRatio = 0.8,
    Duration? followDuration,
    Duration? predictiveWindow,
    this.tilt = const Tilt3D(),
    this.movement = const ZoomMovement(),
    int? id,
  })  : assert(duration > Duration.zero, 'Duration must be positive'),
        id = id ?? _nextId(),
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
        deadzoneRatio = deadzoneRatio.clamp(0.0, 1.5),
        followDuration = (followDuration ?? _defaultFollow).isNegative
            ? Duration.zero
            : (followDuration ?? _defaultFollow),
        predictiveWindow = _clampLeadTime(predictiveWindow ?? _defaultLeadTime);

  /// End time of zoom effect
  Duration get endTime => startTime + duration;

  /// Resolved enter/exit ramp lengths in microseconds: [enterDuration] and
  /// [exitDuration] scaled by [rampDurationScale] (the animation preset's
  /// feel scale), then proportionally squeezed to fit when their sum
  /// exceeds this region's [duration].
  ///
  /// SINGLE SOURCE OF TRUTH for ramp geometry. [ZoomTransformer]'s zoom
  /// factor, [ZoomFocalController]'s enter/exit ramp windows and
  /// [ScenePassBuilder]'s enter-settle cursor sampling must all agree on
  /// where the ramps end: if one of them omits the squeeze it samples the
  /// camera target at an instant the zoom never reaches, and on a short
  /// followCursor region (which has no hold to correct in) the whole zoom
  /// aims somewhere the cursor never was.
  ///
  /// Callers handle the degenerate zero/negative-[duration] case themselves
  /// before calling; this returns zero-length ramps for it.
  ({int enterUs, int exitUs}) resolvedRampsUs(double rampDurationScale) {
    var enterUs = (enterDuration.inMicroseconds * rampDurationScale).round();
    var exitUs = (exitDuration.inMicroseconds * rampDurationScale).round();
    final regionUs = duration.inMicroseconds;
    final totalRamp = enterUs + exitUs;
    if (totalRamp > regionUs && totalRamp > 0) {
      final scale = regionUs / totalRamp;
      enterUs = (enterUs * scale).round();
      exitUs = (exitUs * scale).round();
    }
    return (enterUs: enterUs, exitUs: exitUs);
  }

  /// Check if position is within the zoom region.
  ///
  /// Half-open interval `[startTime, endTime)`: active at the start edge,
  /// inactive exactly at the end edge. This removes the one-frame boundary
  /// ambiguity when two regions share an edge — `isActive` alone resolves
  /// the shared instant to the LATER region. For the canonical "what zoom
  /// is in effect right now (including the exit-ramp completion frame at
  /// endTime)" lookup, use [activeAt]: it adds an explicit `position ==
  /// endTime` check so the just-ended region still wins at shared edges
  /// via loop order, matching the pre-half-open behavior.
  bool isActive(Duration position) {
    return position >= startTime && position < endTime;
  }

  /// Returns the first region whose `[startTime, endTime]` (closed) covers
  /// [position], or null. Uses [isActive] for the open `[start, end)` body
  /// plus an explicit `position == endTime` check so the zoom exit-ramp
  /// completion frame at endTime resolves to the just-ended region — and at
  /// a shared edge, the EARLIER region wins (loop order), preserving the
  /// pre-half-open behavior at shared edges.
  static ZoomRegion? activeAt(
      Duration position, Iterable<ZoomRegion> regions) {
    for (final z in regions) {
      if (z.isActive(position) || position == z.endTime) return z;
    }
    return null;
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
    double? manualPanBackload,
    bool clearManualPanBackload = false,
    bool? followCursor,
    FollowMode? followMode,
    double? deadzoneRatio,
    Duration? followDuration,
    Duration? predictiveWindow,
    Tilt3D? tilt,
    ZoomMovement? movement,
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
      manualPanBackload: clearManualPanBackload
          ? null
          : (manualPanBackload ?? this.manualPanBackload),
      followCursor: followCursor ?? this.followCursor,
      followMode: followMode ?? this.followMode,
      deadzoneRatio: deadzoneRatio ?? this.deadzoneRatio,
      followDuration: followDuration ?? this.followDuration,
      predictiveWindow: predictiveWindow ?? this.predictiveWindow,
      tilt: tilt ?? this.tilt,
      movement: movement ?? this.movement,
      id: id,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'rect': {
        'left': rect.left,
        'top': rect.top,
        'width': rect.width,
        'height': rect.height,
      },
      'startTimeMicros': startTime.inMicroseconds,
      'durationMicros': duration.inMicroseconds,
      'zoomLevel': zoomLevel,
      'enterDurationMicros': enterDuration.inMicroseconds,
      'exitDurationMicros': exitDuration.inMicroseconds,
      if (rampCurveOverride != null)
        'rampCurveOverride': rampCurveOverride!.toJson(),
      if (manualPanBackload != null) 'manualPanBackload': manualPanBackload,
      'followCursor': followCursor,
      'followMode': followMode.name,
      'deadzoneRatio': deadzoneRatio,
      'followDurationMicros': followDuration.inMicroseconds,
      'predictiveWindowMicros': predictiveWindow.inMicroseconds,
      'tilt': tilt.toJson(),
      'movement': movement.toJson(),
    };
  }

  factory ZoomRegion.fromJson(Map<String, dynamic> json) {
    final rectJson = json['rect'];
    if (rectJson is! Map) {
      throw const FormatException('ZoomRegion.fromJson: missing rect');
    }
    final rect = Rect.fromLTWH(
      (rectJson['left'] as num).toDouble(),
      (rectJson['top'] as num).toDouble(),
      (rectJson['width'] as num).toDouble(),
      (rectJson['height'] as num).toDouble(),
    );

    Duration micros(String key) => Duration(
        microseconds: (json[key] as num).toInt());
    Duration? optMicros(String key) => json[key] == null
        ? null
        : Duration(microseconds: (json[key] as num).toInt());

    final modeName = json['followMode'] as String?;
    FollowMode mode = FollowMode.bounded;
    if (modeName != null) {
      FollowMode? matched;
      for (final m in FollowMode.values) {
        if (m.name == modeName) {
          matched = m;
          break;
        }
      }
      if (matched == null) {
        throw FormatException(
            'ZoomRegion.fromJson: unknown followMode "$modeName"');
      }
      mode = matched;
    }

    CubicBezierCurve? parseBezier(Map<String, dynamic>? j) {
      if (j == null) return null;
      final c = AnimationCurve.fromJson(j);
      if (c is! CubicBezierCurve) {
        throw const FormatException(
            'ZoomRegion.fromJson: ramp curve override must be a bezier');
      }
      return c;
    }

    return ZoomRegion(
      rect: rect,
      startTime: micros('startTimeMicros'),
      duration: micros('durationMicros'),
      zoomLevel: (json['zoomLevel'] as num).toDouble(),
      enterDuration: optMicros('enterDurationMicros'),
      exitDuration: optMicros('exitDurationMicros'),
      rampCurveOverride: parseBezier(
          json['rampCurveOverride'] as Map<String, dynamic>?),
      manualPanBackload: (json['manualPanBackload'] as num?)?.toDouble(),
      followCursor: (json['followCursor'] as bool?) ?? true,
      followMode: mode,
      deadzoneRatio: (json['deadzoneRatio'] as num?)?.toDouble() ?? 0.8,
      followDuration: optMicros('followDurationMicros'),
      predictiveWindow: optMicros('predictiveWindowMicros'),
      tilt: json['tilt'] is Map
          ? Tilt3D.fromJson(
              (json['tilt'] as Map).cast<String, dynamic>())
          : const Tilt3D(),
      movement: json['movement'] is Map
          ? ZoomMovement.fromJson(
              (json['movement'] as Map).cast<String, dynamic>())
          : const ZoomMovement(),
    );
  }

  static Duration _clampLeadTime(Duration d) {
    if (d < _minLeadTime) return _minLeadTime;
    if (d > _maxLeadTime) return _maxLeadTime;
    return d;
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
          manualPanBackload == other.manualPanBackload &&
          followCursor == other.followCursor &&
          followMode == other.followMode &&
          deadzoneRatio == other.deadzoneRatio &&
          followDuration == other.followDuration &&
          predictiveWindow == other.predictiveWindow &&
          tilt == other.tilt &&
          movement == other.movement;

  @override
  int get hashCode => Object.hash(
        rect,
        startTime,
        duration,
        zoomLevel,
        enterDuration,
        exitDuration,
        rampCurveOverride,
        manualPanBackload,
        followCursor,
        followMode,
        deadzoneRatio,
        followDuration,
        predictiveWindow,
        tilt,
        movement,
      );
}
