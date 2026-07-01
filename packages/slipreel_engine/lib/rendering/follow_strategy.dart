import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';

/// One frame's decision from a [FollowStrategy]: where should the
/// spring chase, and is the controller currently holding (so it can
/// pick the right damping ratio)?
class FollowResolution {
  const FollowResolution({required this.target, required this.isHolding});

  /// The target the spring should integrate toward. May be the
  /// current focal (signalling "stay put"), the live cursor, or a
  /// derived point (zoom rect centre).
  final Offset target;

  /// True when the strategy reports the focal should NOT move on this
  /// frame — the spring should use overdamped damping to bleed off
  /// residual velocity. False means an active chase; use critical
  /// damping for responsive tracking.
  final bool isHolding;
}

/// Pluggable per-follow-mode rule that decides what the focal spring
/// targets on a given frame.
///
/// Each subclass owns its mode's state (the bounded gate's
/// `_inFlight` flag, etc.). The controller asks `resolve` for a
/// target + holding flag each frame and otherwise stays out of the
/// per-mode logic.
///
/// Before P1-5 every mode's logic lived inline in
/// `ZoomFocalController._resolveTarget`, mixed with gate state, and
/// hold detection used a fragile `target == _smoothedFocal` compare.
/// Lifting each mode into its own class makes them unit-testable in
/// isolation, lets the bounded gate own its `_inFlight` state without
/// polluting the controller, and gives the controller a clean
/// `isHolding` signal direct from the strategy.
abstract class FollowStrategy {
  FollowResolution resolve({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset cursorVelocity,
    required Offset currentFocal,
    required Size videoSize,
    required MotionTuning tuning,
  });

  /// Called when the active zoom region changes so a stateful
  /// strategy (the bounded gate) doesn't carry stale state into the
  /// next region.
  void reset() {}

  /// Read-only view of any "actively chasing" gate state, surfaced
  /// for the debug HUD. Default `false`; the bounded strategy
  /// overrides.
  bool get inFlight => false;
}

/// Cursor-centred follow: target is the live cursor, no gating.
/// When `followCursor` is off, the strategy collapses to the zoom rect centre.
/// When `followCursor` is on but the cursor is unavailable, it falls back to
/// video center so stale manual placement does not affect auto-follow.
///
/// `predictive` mode does NOT use this strategy — it is an anticipatory
/// deadzone follow (see [PredictiveFollowStrategy]).
class CenteredFollowStrategy extends FollowStrategy {
  @override
  FollowResolution resolve({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset cursorVelocity,
    required Offset currentFocal,
    required Size videoSize,
    required MotionTuning tuning,
  }) {
    if (!zoom.followCursor) {
      return _fixedTarget(zoom.rect.center, currentFocal);
    }
    if (cursor == null) {
      return _fixedTarget(_baseFocalForFollow(zoom, videoSize), currentFocal);
    }
    return FollowResolution(target: cursor, isHolding: false);
  }
}

/// Cursor-follow with a deadzone gate, parameterized by the AIM point each
/// subclass chooses (raw cursor for bounded; velocity-led cursor for
/// predictive). The cursor pins the focal while the aim point is inside the
/// deadzone; crossing the boundary starts a chase that re-centers the cursor
/// and then holds.
///
/// **Engage-positional, release-hysteretic.** Engagement is purely positional
/// (aim outside the deadzone ⇒ chase) so hover jitter inside the dz never
/// starts a chase from noise. Release waits until the chase has re-centered the
/// aim into an INNER zone ([_releaseInnerRatio] of the deadzone) AND the
/// cursor's scene velocity is below [MotionTuning.cursorAtRestPxPerSec]. The
/// inner/outer hysteresis means a breach pans DECISIVELY to re-center the
/// cursor instead of releasing the instant it re-touches the outer edge —
/// without it, a cursor parked at the deadzone boundary made the camera creep
/// with every small movement.
abstract class _DeadzoneFollowStrategy extends FollowStrategy {
  /// Inner "release" zone as a fraction of the deadzone. Once engaged, the
  /// chase continues until the aim is within `deadzone * _releaseInnerRatio`
  /// of the focal (re-centered), then the gate may hold. Smaller = the camera
  /// re-centers the cursor more before holding (bigger free-movement buffer
  /// afterward); 1.0 reproduces the old release-at-the-edge behavior.
  static const double _releaseInnerRatio = 0.5;

  bool _inFlight = false;

  @override
  bool get inFlight => _inFlight;

  @override
  void reset() {
    _inFlight = false;
  }

  /// The point the camera aims at this frame.
  Offset aimPoint(ZoomRegion zoom, Offset cursor, Offset cursorVelocity);

  @override
  FollowResolution resolve({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset cursorVelocity,
    required Offset currentFocal,
    required Size videoSize,
    required MotionTuning tuning,
  }) {
    final boundsActive = zoom.followCursor &&
        cursor != null &&
        zoom.deadzoneRatio > 0 &&
        videoSize.width > 0 &&
        videoSize.height > 0;
    if (!boundsActive) {
      _inFlight = false;
      if (!zoom.followCursor) {
        return _fixedTarget(zoom.rect.center, currentFocal);
      }
      if (cursor == null) {
        return _fixedTarget(_baseFocalForFollow(zoom, videoSize), currentFocal);
      }
      return FollowResolution(target: cursor, isHolding: false);
    }

    final aim = aimPoint(zoom, cursor, cursorVelocity);
    final z = zoom.zoomLevel;
    final dzW = (videoSize.width / z) * zoom.deadzoneRatio;
    final dzH = (videoSize.height / z) * zoom.deadzoneRatio;
    final dz = Rect.fromCenter(center: currentFocal, width: dzW, height: dzH);

    if (_inFlight) {
      final cursorAtRest =
          cursorVelocity.distance < tuning.cursorAtRestPxPerSec;
      // Hold only once the chase has re-centered the aim into the inner zone
      // (not merely back inside the outer deadzone edge). This decisive
      // re-center is what stops small movements near the boundary from
      // creeping the camera.
      final innerDz = Rect.fromCenter(
        center: currentFocal,
        width: dzW * _releaseInnerRatio,
        height: dzH * _releaseInnerRatio,
      );
      if (cursorAtRest && innerDz.contains(aim)) {
        _inFlight = false;
        return FollowResolution(target: currentFocal, isHolding: true);
      }
      return FollowResolution(target: aim, isHolding: false);
    }

    if (dz.contains(aim)) {
      return FollowResolution(target: currentFocal, isHolding: true);
    }
    _inFlight = true;
    return FollowResolution(target: aim, isHolding: false);
  }
}

/// Reactive deadzone follow: aims at the raw cursor (no look-ahead).
class BoundedFollowStrategy extends _DeadzoneFollowStrategy {
  @override
  Offset aimPoint(ZoomRegion zoom, Offset cursor, Offset cursorVelocity) =>
      cursor;
}

/// Anticipatory deadzone follow: aims at the velocity-led cursor
/// (`cursor + velocity·leadTime`) so the camera starts panning before the
/// cursor reaches the deadzone edge. Lead time is [ZoomRegion.predictiveWindow].
///
/// The lead FADES IN with cursor speed (smoothstep between
/// [_leadFadeStartPxPerSec] and [_leadFadeFullPxPerSec]) — mirroring the cursor
/// sprite's feedforward fade. Slow / jittery motion gets ~no lead, so small
/// movements don't get amplified past the deadzone into camera jitter; fast,
/// deliberate motion gets the full anticipation. At rest the lead is zero ⇒
/// aim == cursor ⇒ no overshoot on click landings.
class PredictiveFollowStrategy extends _DeadzoneFollowStrategy {
  static const double _leadFadeStartPxPerSec = 200.0;
  static const double _leadFadeFullPxPerSec = 900.0;

  @override
  Offset aimPoint(ZoomRegion zoom, Offset cursor, Offset cursorVelocity) {
    final speed = cursorVelocity.distance;
    const range = _leadFadeFullPxPerSec - _leadFadeStartPxPerSec;
    final t = ((speed - _leadFadeStartPxPerSec) / range).clamp(0.0, 1.0);
    final fade = t * t * (3.0 - 2.0 * t); // smoothstep
    final leadSec = (zoom.predictiveWindow.inMicroseconds / 1e6) * fade;
    return cursor + cursorVelocity * leadSec;
  }
}

/// Pick the right strategy for a [FollowMode]. Called by the
/// controller when the active zoom region changes; the result is
/// cached for the lifetime of that region so the bounded gate's
/// `_inFlight` persists across frames.
FollowStrategy followStrategyFor(FollowMode mode) {
  switch (mode) {
    case FollowMode.bounded:
      return BoundedFollowStrategy();
    case FollowMode.predictive:
      return PredictiveFollowStrategy();
    case FollowMode.centered:
      return CenteredFollowStrategy();
  }
}

Offset _baseFocalForFollow(ZoomRegion zoom, Size videoSize) {
  if (!zoom.followCursor) return zoom.rect.center;
  return Offset(videoSize.width / 2, videoSize.height / 2);
}

FollowResolution _fixedTarget(Offset target, Offset currentFocal) {
  return FollowResolution(
    target: target,
    isHolding: (target - currentFocal).distance < 0.5,
  );
}
