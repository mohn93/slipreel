import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart' show Offset, Rect, Size;
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';

/// Stateful controller for the cursor-follow zoom focal point.
///
/// Each [update] call advances a duration-based catch-up tween: when
/// the cursor leaves the deadzone (or [ZoomRegion.followCursor] flips
/// off) the controller captures the current focal as the tween's
/// `from`, the new target as the tween's `to`, and stamps a start
/// position. Each subsequent frame interpolates with
/// `curve(elapsed / followDuration)`.
///
/// While a tween is in flight the target can move (the cursor keeps
/// drifting) and the controller updates `to` without resetting
/// `from` or `elapsed` — that gives a smooth chase curve instead of
/// snapping back to a stale snapshot. If the cursor wanders back
/// inside the deadzone of the *current* focal, the tween aborts and
/// the focal sticks where it landed.
///
/// First-frame behavior is unchanged: entering a fresh zoom snaps to
/// its initial target so we don't lerp across the screen.
class ZoomFocalController {
  ZoomRegion? _previousActiveZoom;
  Offset? _smoothedFocal;

  // Active catch-up tween. `_tweenStartPosition == null` ⇒ no tween
  // is in flight and `_smoothedFocal` is the resting focal.
  Offset? _tweenFrom;
  Offset? _tweenTo;
  Duration? _tweenStartPosition;

  /// Cached `(position → result)` for the most recent [update] call.
  /// Calling again with the same [position] returns the cached value
  /// without advancing the tween — otherwise a parent setState that
  /// triggers an extra builder run for the same frame would advance
  /// the focal twice and visibly jump.
  Duration? _cachedPosition;
  ZoomFocalUpdate? _cachedResult;

  /// Last computed focal. Exposed for the debug HUD that draws the
  /// focal as a hollow yellow ring.
  Offset? get smoothedFocal => _smoothedFocal;

  /// Compute the focal for the current frame.
  ///
  /// Returns `null` when no zoom region is active at [position].
  /// Idempotent for the same [position] — see [_cachedPosition].
  ///
  /// [videoSize] is the source video resolution and feeds the
  /// deadzone box (`videoSize / zoom.zoomLevel * deadzoneRatio`).
  ZoomFocalUpdate? update({
    required Duration position,
    required List<ZoomRegion> zoomRegions,
    required CursorRecording cursorRecording,
    required Size videoSize,
  }) {
    if (_cachedPosition == position) {
      return _cachedResult;
    }
    _cachedPosition = position;

    final activeZoom = _activeZoomAt(position, zoomRegions);
    if (activeZoom == null) {
      _previousActiveZoom = null;
      _smoothedFocal = null;
      _resetTween();
      _cachedResult = null;
      return null;
    }

    final cursor = cursorAt(cursorRecording, position);
    final cursorOffset =
        cursor == null ? null : Offset(cursor.x, cursor.y);

    // First frame of this zoom: snap, never lerp.
    if (!identical(activeZoom, _previousActiveZoom)) {
      _previousActiveZoom = activeZoom;
      final initial = _initialTarget(activeZoom, cursorOffset);
      _smoothedFocal = initial;
      _resetTween();
      _cachedResult = ZoomFocalUpdate(zoom: activeZoom, focal: initial);
      return _cachedResult;
    }

    // Step 1 — advance any in-flight tween before we look at the
    // target so the deadzone check uses the freshest focal.
    if (_tweenStartPosition != null) {
      final dur = activeZoom.followDuration;
      final elapsedMicros =
          position.inMicroseconds - _tweenStartPosition!.inMicroseconds;
      if (dur.inMicroseconds <= 0 || elapsedMicros >= dur.inMicroseconds) {
        _smoothedFocal = _tweenTo;
        _resetTween();
      } else {
        final t = (elapsedMicros / dur.inMicroseconds).clamp(0.0, 1.0);
        final eased = _resolveCurve(activeZoom).transform(t);
        _smoothedFocal = Offset.lerp(_tweenFrom, _tweenTo, eased)!;
      }
    }

    // Step 2 — figure out where the camera *should* be aiming this
    // frame, given the freshly-advanced focal.
    final target = _resolveTarget(
      zoom: activeZoom,
      cursor: cursorOffset,
      currentFocal: _smoothedFocal!,
      videoSize: videoSize,
    );

    if (_tweenStartPosition == null) {
      // Idle. Start a tween if the target moved off the focal.
      if (_distanceSquared(target, _smoothedFocal!) > _moveEpsilonSq) {
        if (activeZoom.followDuration.inMicroseconds <= 0) {
          // Zero-duration "snap" mode — apply this frame, no tween.
          _smoothedFocal = target;
        } else {
          _tweenFrom = _smoothedFocal;
          _tweenTo = target;
          _tweenStartPosition = position;
        }
      }
    } else {
      // Tweening. Three sub-cases:
      //   a) Target is essentially where the focal already is — the
      //      cursor wandered back into the deadzone, so abort and let
      //      the focal stick. (Without this, a brief deadzone re-entry
      //      followed by the tween finishing would snap to the stale
      //      `to`.)
      //   b) Target is the same as our current `to` — keep tweening.
      //   c) Target moved — re-aim `to` while preserving `from` and
      //      the start position so `elapsed` keeps growing.
      if (_distanceSquared(target, _smoothedFocal!) <= _moveEpsilonSq) {
        _resetTween();
      } else if (_distanceSquared(target, _tweenTo!) > _moveEpsilonSq) {
        _tweenTo = target;
      }
    }

    _cachedResult =
        ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
    return _cachedResult;
  }

  /// Drop all smoothing state. Use when switching to a different
  /// recording, scrubbing past a zoom region, or in tests.
  void reset() {
    _previousActiveZoom = null;
    _smoothedFocal = null;
    _resetTween();
    _cachedPosition = null;
    _cachedResult = null;
  }

  // --- internals --------------------------------------------------

  void _resetTween() {
    _tweenFrom = null;
    _tweenTo = null;
    _tweenStartPosition = null;
  }

  static const double _moveEpsilonSq = 1e-4; // 0.01 px

  static double _distanceSquared(Offset a, Offset b) {
    final dx = a.dx - b.dx;
    final dy = a.dy - b.dy;
    return dx * dx + dy * dy;
  }

  /// What the focal would be on the very first frame of [zoom].
  static Offset _initialTarget(ZoomRegion zoom, Offset? cursor) {
    if (!zoom.followCursor || cursor == null) {
      return zoom.rect.center;
    }
    return cursor;
  }

  /// Where the camera should aim this frame. May equal [currentFocal]
  /// (cursor inside deadzone, or zoom configured for static focal).
  static Offset _resolveTarget({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset currentFocal,
    required Size videoSize,
  }) {
    if (!zoom.followCursor || cursor == null) {
      return zoom.rect.center;
    }
    if (!zoom.boundedFollow ||
        zoom.deadzoneRatio <= 0 ||
        videoSize.width <= 0 ||
        videoSize.height <= 0) {
      return cursor;
    }
    final z = zoom.zoomLevel;
    final dzW = (videoSize.width / z) * zoom.deadzoneRatio;
    final dzH = (videoSize.height / z) * zoom.deadzoneRatio;
    final dz = Rect.fromCenter(
      center: currentFocal,
      width: dzW,
      height: dzH,
    );
    return dz.contains(cursor) ? currentFocal : cursor;
  }

  static Curve _resolveCurve(ZoomRegion zoom) =>
      zoom.followCurve?.toFlutterCurve() ?? Curves.easeOutCubic;

  static ZoomRegion? _activeZoomAt(
    Duration position,
    List<ZoomRegion> zoomRegions,
  ) {
    for (final z in zoomRegions) {
      if (z.isActive(position)) return z;
    }
    return null;
  }
}

/// Result of a [ZoomFocalController.update] call when a zoom is active.
class ZoomFocalUpdate {
  const ZoomFocalUpdate({required this.zoom, required this.focal});
  final ZoomRegion zoom;
  final Offset focal;
}
