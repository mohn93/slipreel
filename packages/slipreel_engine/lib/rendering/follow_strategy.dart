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
/// When `followCursor` is off or the cursor is unavailable, the
/// strategy collapses to the zoom rect centre with holding=true.
///
/// `predictive` mode reuses this same strategy — the differentiator
/// is upstream (the scene builder passes the rolling-median cursor
/// for predictive instead of the spring-smoothed sprite).
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
    if (!zoom.followCursor || cursor == null) {
      return FollowResolution(target: zoom.rect.center, isHolding: true);
    }
    return FollowResolution(target: cursor, isHolding: false);
  }
}

/// Cursor-follow with a deadzone gate. The cursor pins the focal in
/// place while inside the deadzone; crossing the boundary starts a
/// chase that releases only when the cursor comes to rest inside the
/// dz again.
///
/// **Engage-positional, release-velocity-aware.** Engagement is
/// purely positional (cursor outside dz ⇒ chase) so hover jitter
/// inside the dz never starts a chase from noise. Release requires
/// BOTH the cursor inside the dz AND the cursor's intrinsic scene
/// velocity below [MotionTuning.cursorAtRestPxPerSec] — without the
/// velocity check, a continuously-moving cursor would gate-cycle as
/// the spring's settled lag (`τ × v`) places the cursor inside the dz
/// release area.
class BoundedFollowStrategy extends FollowStrategy {
  bool _inFlight = false;

  @override
  bool get inFlight => _inFlight;

  @override
  void reset() {
    _inFlight = false;
  }

  @override
  FollowResolution resolve({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset cursorVelocity,
    required Offset currentFocal,
    required Size videoSize,
    required MotionTuning tuning,
  }) {
    // Degenerate cases: no cursor, follow-off, no deadzone — behave
    // like centered/no-follow.
    final boundsActive = zoom.followCursor &&
        cursor != null &&
        zoom.deadzoneRatio > 0 &&
        videoSize.width > 0 &&
        videoSize.height > 0;
    if (!boundsActive) {
      _inFlight = false;
      if (!zoom.followCursor || cursor == null) {
        return FollowResolution(target: zoom.rect.center, isHolding: true);
      }
      return FollowResolution(target: cursor, isHolding: false);
    }

    final z = zoom.zoomLevel;
    final dzW = (videoSize.width / z) * zoom.deadzoneRatio;
    final dzH = (videoSize.height / z) * zoom.deadzoneRatio;
    final dz = Rect.fromCenter(
      center: currentFocal,
      width: dzW,
      height: dzH,
    );

    if (_inFlight) {
      // Release condition: cursor inside dz AND at rest.
      final cursorAtRest =
          cursorVelocity.distance < tuning.cursorAtRestPxPerSec;
      if (cursorAtRest && dz.contains(cursor)) {
        _inFlight = false;
        return FollowResolution(target: currentFocal, isHolding: true);
      }
      // Still chasing.
      return FollowResolution(target: cursor, isHolding: false);
    }

    // Not currently chasing. Engagement is strictly positional.
    if (dz.contains(cursor)) {
      return FollowResolution(target: currentFocal, isHolding: true);
    }
    _inFlight = true;
    return FollowResolution(target: cursor, isHolding: false);
  }
}

/// Predictive follow: same target rule as centered (the caller passes
/// the median-cursor in for `cursor`); no gate. Kept as a distinct
/// type so the controller's strategy lookup is exhaustive on
/// [FollowMode] and a future predictive-specific behavior has a
/// natural home.
class PredictiveFollowStrategy extends CenteredFollowStrategy {}

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
