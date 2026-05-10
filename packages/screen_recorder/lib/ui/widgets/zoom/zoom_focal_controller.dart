import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart' show Offset, Rect, Size;
import 'package:screen_recorder/models/zoom_region.dart';

/// Stateful controller for the cursor-follow zoom focal point.
///
/// The caller passes in a [cursor] offset that has already been
/// resolved against the recording (and ideally smoothed by the same
/// pipeline that paints the visible cursor sprite — otherwise the
/// camera tracks a different cursor than the one on screen and the
/// sprite visibly drifts off-center during zooms).
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

  // Duration of the in-flight tween. May differ from
  // `zoom.followDuration` when a tween starts mid-enter-ramp — see
  // `_tweenDurationFor` for the sync rationale.
  Duration? _tweenDuration;

  // Last [position] passed to [update]. Used to detect backward
  // scrubs so the controller can snap to the cursor instead of
  // freezing on stale tween state. Large *forward* jumps are left
  // to the existing deadzone logic — when the cursor is still inside
  // the deadzone at the new position, the focal should hold (match
  // forward-playback behavior). Only the backward case has no good
  // continuation.
  Duration? _lastUpdatePosition;

  // Focal at the moment the exit ramp started. Captured once on the
  // first frame inside the exit ramp; cleared whenever the controller
  // leaves the exit ramp (zoom changes, scrubs back into the hold,
  // etc.) so the next exit captures fresh.
  Offset? _exitRampStartFocal;

  /// Last computed focal. Exposed for the debug HUD that draws the
  /// focal as a hollow yellow ring.
  Offset? get smoothedFocal => _smoothedFocal;

  /// Compute the focal for the current frame.
  ///
  /// Returns `null` when no zoom region is active at [position].
  /// Idempotent for the same set of inputs — repeated calls at the
  /// same position with the same active zoom and cursor produce the
  /// same focal (the tween logic only advances when the inputs
  /// genuinely change), so settings edits at a paused position take
  /// effect on the very next render rather than waiting for the
  /// playhead to move.
  ///
  /// [cursor] is the cursor position in source-video pixels for this
  /// frame. Pass the same value the visible cursor sprite is drawn at
  /// so the camera and the sprite track each other; pass `null` when
  /// no cursor data is available (legacy / window-source / pre-warmup).
  ///
  /// [videoSize] is the source video resolution and feeds the
  /// deadzone box (`videoSize / zoom.zoomLevel * deadzoneRatio`).
  ZoomFocalUpdate? update({
    required Duration position,
    required List<ZoomRegion> zoomRegions,
    required Offset? cursor,
    required Size videoSize,
    bool forceSnap = false,
  }) {
    final activeZoom = _activeZoomAt(position, zoomRegions);
    if (activeZoom == null) {
      _previousActiveZoom = null;
      _smoothedFocal = null;
      _resetTween();
      _exitRampStartFocal = null;
      _lastUpdatePosition = position;
      return null;
    }

    // First frame of this zoom: snap, never lerp.
    if (!identical(activeZoom, _previousActiveZoom)) {
      _previousActiveZoom = activeZoom;
      final initial = _initialTarget(activeZoom, cursor);
      _smoothedFocal = initial;
      _resetTween();
      _exitRampStartFocal = null;
      _lastUpdatePosition = position;
      return ZoomFocalUpdate(zoom: activeZoom, focal: initial);
    }

    // [forceSnap] / backward scrub: the tween's state assumes forward
    // time progression, so mid-tween scrub-backwards leaves
    // elapsed=negative and the focal frozen at `_tweenFrom`. Snap to
    // the cursor at the new position and let forward motion re-
    // establish smoothing. [forceSnap] gives the caller (hover-scrub
    // preview) a way to opt in to the same direction-agnostic snap so
    // forward and backward hover land on the same focal at the same T.
    if (forceSnap ||
        (_lastUpdatePosition != null && position < _lastUpdatePosition!)) {
      final snap = _initialTarget(activeZoom, cursor);
      _smoothedFocal = snap;
      _resetTween();
      _exitRampStartFocal = null;
      _lastUpdatePosition = position;
      return ZoomFocalUpdate(zoom: activeZoom, focal: snap);
    }
    _lastUpdatePosition = position;

    // Step 1 — advance any in-flight tween before we look at the
    // target so the deadzone check uses the freshest focal.
    if (_tweenStartPosition != null) {
      final dur = _tweenDuration!;
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

    // Inside the exit ramp the zoom factor is decreasing every frame,
    // so the visible viewport keeps widening — the user can already
    // see where the cursor is heading without the camera chasing it.
    // Stop tracking the cursor here, but smoothly migrate the focal
    // toward the video center so X and Y arrive simultaneously when
    // the zoom hits 1.0×. Without this lerp the per-axis clamp in
    // ZoomTransformer pulls X and Y inward at different rates (the
    // axis with the larger frozen offset gets clamped first, the
    // other one snaps to centre only on the final identity frame),
    // which the user reads as "X moved, Y didn't, then Y jumped".
    final exit = _exitRampWindow(activeZoom);
    if (exit != null) {
      final tIntoRegionUs =
          position.inMicroseconds - activeZoom.startTime.inMicroseconds;
      if (tIntoRegionUs >= exit.exitStartUs) {
        _exitRampStartFocal ??= _smoothedFocal;
        final tIntoExit = (tIntoRegionUs - exit.exitStartUs)
            .clamp(0, exit.exitUs);
        final tNorm =
            exit.exitUs == 0 ? 1.0 : tIntoExit / exit.exitUs;
        // Same curve the ZoomTransformer applies to the zoom factor
        // (its rampCurve default). Keeping these in lock-step is what
        // makes the recenter feel like part of the zoom-out instead
        // of a separate motion.
        final eased = Curves.easeInOutQuad.transform(tNorm.toDouble());
        final centre = Offset(videoSize.width / 2, videoSize.height / 2);
        _smoothedFocal = Offset.lerp(_exitRampStartFocal, centre, eased);
        return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
      }
    }
    // Outside the exit ramp — clear the captured anchor so the next
    // entry into an exit ramp re-captures from a fresh position.
    _exitRampStartFocal = null;

    // Step 2 — decide what the camera should aim at this frame.
    //
    // The deadzone is a *trigger*, not a containment: it only gates
    // whether a NEW tween starts. Once a tween is in flight we keep
    // aiming at the cursor every frame (same shape as always-centered)
    // so the focal smoothly chases instead of stuttering as the
    // moving deadzone briefly re-contains the cursor each frame.
    final baseTarget = _baseTarget(activeZoom, cursor);

    if (_tweenStartPosition == null) {
      // Idle. Engage the deadzone gate before starting a tween.
      final shouldStart = _shouldStartTween(
        zoom: activeZoom,
        cursor: cursor,
        baseTarget: baseTarget,
        currentFocal: _smoothedFocal!,
        videoSize: videoSize,
      );
      if (shouldStart) {
        final dur = _tweenDurationFor(zoom: activeZoom, position: position);
        if (dur.inMicroseconds <= 0) {
          // Zero-duration "snap" mode — apply this frame, no tween.
          _smoothedFocal = baseTarget;
        } else {
          _tweenFrom = _smoothedFocal;
          _tweenTo = baseTarget;
          _tweenStartPosition = position;
          _tweenDuration = dur;
        }
      }
    } else {
      // Tweening: re-aim `to` toward the latest base target while
      // preserving `from` and the start position so `elapsed` keeps
      // growing. The deadzone re-engages on the NEXT idle frame,
      // not mid-tween.
      if (_distanceSquared(baseTarget, _tweenTo!) > _moveEpsilonSq) {
        _tweenTo = baseTarget;
      }
    }

    return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
  }

  /// Drop all smoothing state. Use when switching to a different
  /// recording, scrubbing past a zoom region, or in tests.
  void reset() {
    _previousActiveZoom = null;
    _smoothedFocal = null;
    _resetTween();
    _exitRampStartFocal = null;
    _lastUpdatePosition = null;
  }

  // --- internals --------------------------------------------------

  void _resetTween() {
    _tweenFrom = null;
    _tweenTo = null;
    _tweenStartPosition = null;
    _tweenDuration = null;
  }

  /// Exit ramp window for [zoom] in microseconds-into-region — the
  /// last [ZoomRegion.exitDuration] post-squeeze when enter+exit
  /// exceed the region length. Returns null when there's no exit
  /// ramp to enter (zero-length region or zero exit duration).
  /// Mirrors the same squeeze math [_tweenDurationFor] uses so the
  /// two stay in sync.
  static ({int exitStartUs, int exitUs})? _exitRampWindow(ZoomRegion zoom) {
    final regionUs = zoom.duration.inMicroseconds;
    if (regionUs <= 0) return null;

    var enterUs = zoom.enterDuration.inMicroseconds;
    var exitUs = zoom.exitDuration.inMicroseconds;
    final totalRamp = enterUs + exitUs;
    if (totalRamp > regionUs && totalRamp > 0) {
      final scale = regionUs / totalRamp;
      enterUs = (enterUs * scale).round();
      exitUs = (exitUs * scale).round();
    }
    if (exitUs <= 0) return null;
    final exitStartUs = regionUs - exitUs;
    return (exitStartUs: exitStartUs, exitUs: exitUs);
  }

  /// Pick a tween duration that keeps the camera pan and the zoom
  /// ramp ending at the same instant.
  ///
  /// Inside the enter ramp the focal-follow tween is sized so it
  /// completes exactly when the zoom factor hits [zoomLevel] — that
  /// way the camera arriving at the cursor and the zoom finishing
  /// look like one motion instead of two staggered ones. Same logic
  /// for the exit ramp on the way back out. Mid-zoom (in the hold
  /// phase) cursor moves keep using the user-tuned [followDuration]
  /// because there's no co-running ramp to align with.
  static Duration _tweenDurationFor({
    required ZoomRegion zoom,
    required Duration position,
  }) {
    final regionStartUs = zoom.startTime.inMicroseconds;
    final tIntoRegionUs = position.inMicroseconds - regionStartUs;
    final regionUs = zoom.duration.inMicroseconds;
    if (tIntoRegionUs < 0 || regionUs <= 0) {
      return zoom.followDuration;
    }

    var enterUs = zoom.enterDuration.inMicroseconds;
    var exitUs = zoom.exitDuration.inMicroseconds;
    final totalRamp = enterUs + exitUs;
    if (totalRamp > regionUs && totalRamp > 0) {
      // Match ZoomTransformer._calculateZoomFactor's proportional
      // squeeze when the region can't fit both ramps at full length.
      final scale = regionUs / totalRamp;
      enterUs = (enterUs * scale).round();
      exitUs = (exitUs * scale).round();
    }

    if (tIntoRegionUs < enterUs) {
      return Duration(microseconds: enterUs - tIntoRegionUs);
    }
    final exitStartUs = regionUs - exitUs;
    if (tIntoRegionUs >= exitStartUs && exitUs > 0) {
      final remaining = regionUs - tIntoRegionUs;
      return remaining > 0
          ? Duration(microseconds: remaining)
          : zoom.followDuration;
    }
    return zoom.followDuration;
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

  /// "Base" target this frame, ignoring the deadzone — the cursor
  /// when we're following it, or the zoom's static center otherwise.
  /// Used both as a tween's `to` value and as the comparison point
  /// for the deadzone gate.
  static Offset _baseTarget(ZoomRegion zoom, Offset? cursor) {
    if (!zoom.followCursor || cursor == null) {
      return zoom.rect.center;
    }
    return cursor;
  }

  /// Whether an idle controller should kick off a fresh tween this
  /// frame. For bounded follow we check the deadzone; for everything
  /// else we just look at whether the base target moved off the
  /// current focal.
  static bool _shouldStartTween({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset baseTarget,
    required Offset currentFocal,
    required Size videoSize,
  }) {
    if (_distanceSquared(baseTarget, currentFocal) <= _moveEpsilonSq) {
      return false;
    }
    final boundsActive = zoom.followCursor &&
        zoom.followMode == FollowMode.bounded &&
        cursor != null &&
        zoom.deadzoneRatio > 0 &&
        videoSize.width > 0 &&
        videoSize.height > 0;
    if (!boundsActive) {
      return true;
    }
    final z = zoom.zoomLevel;
    final dzW = (videoSize.width / z) * zoom.deadzoneRatio;
    final dzH = (videoSize.height / z) * zoom.deadzoneRatio;
    final dz = Rect.fromCenter(
      center: currentFocal,
      width: dzW,
      height: dzH,
    );
    return !dz.contains(cursor);
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
