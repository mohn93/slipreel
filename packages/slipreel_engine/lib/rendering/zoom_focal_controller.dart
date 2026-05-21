import 'package:flutter/animation.dart' show Curves;
import 'package:flutter/painting.dart' show Offset, Rect, Size;
import 'package:slipreel_engine/models/zoom_region.dart';

/// Stateful controller for the cursor-follow zoom focal point.
///
/// The caller passes in a [cursor] offset that has already been
/// resolved against the recording (and ideally smoothed by the same
/// pipeline that paints the visible cursor sprite — otherwise the
/// camera tracks a different cursor than the one on screen and the
/// sprite visibly drifts off-center during zooms).
///
/// Internally the focal is a critically-damped 2nd-order spring per
/// axis. Each [update] resolves a target for the frame, then
/// integrates the spring forward by `position − prevPosition` of
/// video time (sub-stepped at ≤16 ms slices for stability). The
/// camera therefore has continuous velocity AND acceleration, which
/// structurally rules out the velocity discontinuities that the old
/// duration-tween + EMA chain could produce when the cursor flicked
/// or playback skipped frames.
///
/// First-frame behaviour is unchanged: entering a fresh zoom snaps
/// to its initial target so we don't lerp across the screen. The
/// exit-ramp `easeInOutQuad` lerp-to-centre branch is also unchanged
/// — the spring is only active during the hold phase and the enter
/// ramp.
class ZoomFocalController {
  ZoomRegion? _previousActiveZoom;
  Offset? _smoothedFocal;

  // Spring state — velocity in source-video pixels per second, per
  // axis. Position lives in [_smoothedFocal]. Both reset to zero on
  // any snap path so a discontinuity (new zoom, reverse scrub,
  // forceSnap) doesn't carry stale velocity across the boundary.
  double _focalVx = 0;
  double _focalVy = 0;

  // Diagnostic — most-recent snap event for the debug HUD. The HUD
  // shows ("freshZoom", "reverseScrub", "forceSnap", or null) plus
  // the playhead at which it fired, so we can tell at a glance which
  // path is responsible when the user reports a "the camera suddenly
  // recentred on the cursor" glitch.
  String? _lastSnapReason;
  Duration? _lastSnapAt;

  /// Most-recent snap reason (or null if no snap has happened on this
  /// controller). Exposed for the debug HUD.
  String? get lastSnapReason => _lastSnapReason;

  /// Playhead at which [lastSnapReason] fired. Exposed for the HUD.
  Duration? get lastSnapAt => _lastSnapAt;

  // Bounded-mode "cursor outside the deadzone right now" flag. Pure
  // per-frame state — set when this frame's cursor is outside the
  // deadzone, cleared the moment the cursor re-enters it.
  //
  // The earlier design latched this flag through the entire chase so
  // a transient cursor return inside the moving deadzone wouldn't
  // abort. That preserves a ScreenStudio-style "commit to chase"
  // semantic but produces a sticky latch: an earlier off-screen
  // cursor excursion can leave the spring chasing for a long time
  // even after the cursor settles back inside the deadzone, which
  // the user reads as the camera drifting in a small zone for no
  // visible reason. The leash semantic (hold the moment the cursor
  // is inside the dz again, regardless of prior history) is closer
  // to user intent and trivially explainable.
  bool _inFlight = false;

  // Last [position] passed to [update]. Used for two purposes:
  // (1) detect backward scrubs that should snap rather than integrate;
  // (2) compute `dt` for the spring step.
  Duration? _lastUpdatePosition;

  // Focal at the moment the exit ramp started. Captured once on the
  // first frame inside the exit ramp; cleared whenever the controller
  // leaves the exit ramp so the next exit captures fresh.
  Offset? _exitRampStartFocal;

  // Floor for the backward-scrub-detection check.
  //
  // Originally 10 ms — anything below was treated as scheduling
  // noise. Bumped to **200 ms** because the previous floor was
  // misfiring on a common UX path: when the user finishes a hover-
  // scrub by clicking the timeline, the committed playhead can land
  // 30–100 ms *behind* the last hover preview (different mouse-up
  // pixel + the brief delay before the player applies seekTo).
  // That registered as a backward scrub and snapped the focal to
  // the cursor — which is exactly the "the camera suddenly centres
  // on my cursor" complaint. Real, user-intended backward seeks
  // (clicking a much earlier point on the timeline, keyboard
  // scrubbing, etc.) are still always larger than 200 ms, so the
  // snap path stays available for the cases that actually need it.
  static const int _reverseScrubMinMicros = 200 * 1000;

  // Largest sub-step the spring is integrated over. Semi-implicit
  // Euler is stable for damped-spring systems while `c·dt < 2`; for
  // the minimum allowed settleTime (100 ms) `c = 4/T = 40`, so
  // `dt < 50 ms`. 16 ms (one 60 fps frame) keeps the integration
  // well inside that band for every supported [ZoomRegion.followDuration].
  static const int _maxSubStepMicros = 16 * 1000;

  // Hard cap on the *total* dt fed into a single update. After a
  // pause-resume the next call may carry a multi-second gap; capping
  // at 250 ms keeps sub-step counts bounded (≤16 sub-steps) and the
  // spring effectively jumps to the new state on the following frame.
  static const int _maxTotalDtMicros = 250 * 1000;

  // Velocity threshold (px/s) at which the bounded-mode gate
  // considers the cursor "at rest" and is allowed to release an
  // in-flight chase.
  //
  // The pure-positional gate cycles for any continuously-moving
  // cursor: a critically-damped spring chasing a moving cursor
  // settles at a steady-state lag of `τ · v`, and for any sensible
  // preset (τ ≈ 75–150 ms) that lag is **smaller** than the
  // deadzone half-width — so the cursor sits inside the gate's
  // release area during chase, the gate releases, the spring
  // decelerates, the cursor drifts back out, chase re-engages, ad
  // infinitum at ~6–10 Hz. Wider positional hysteresis just makes
  // the cycle slower without breaking it (the steady-state lag
  // still beats any band you can pick without making the dz
  // effectively useless).
  //
  // Adding a velocity gate breaks the cycle cleanly: during a
  // continuous chase the cursor's intrinsic scene velocity is high
  // (hundreds of px/s for typical motion), so the gate stays
  // engaged regardless of cursor-vs-dz position. Once the user
  // stops moving the cursor, scene velocity drops below
  // [_cursorAtRestPxPerSec] within ~33 ms (the velocity lookback
  // window), the gate releases, the spring's overdamped hold
  // decelerates it, and the camera comes to rest.
  //
  // **Threshold rationale (80 px/s)**: live HUD evidence shows the
  // "cursor is stopped" noise floor sits at ~30–35 px/s in
  // scene-velocity terms. Sources of the floor: click events
  // inject extra samples whose position can land 2–5 px off the
  // timer-grid trajectory (NSEvent.mouseLocation is read at the
  // event's dispatch moment, slightly off the timer ticks); the
  // screen→video coordinate transform scales sub-pixel screen
  // jitter up by `videoWidth / screenWidth` (~1.15× on Retina);
  // and steady-hand tremor itself is a few px/s. A 30 px/s
  // threshold (the previous value) sits right ON that floor — the
  // gate sees a stopped cursor as "still moving" and never
  // releases the chase, which produces a visible "snap" as the
  // spring continues converging at its peak velocity (in one
  // observed HUD frame: 1145 px/s with 250 px to close → ~2290
  // px/s on a 2× zoom).
  //
  // 80 px/s is comfortably above the ~35 px/s observed noise floor
  // and well below typical intentional motion (~200+ px/s for even
  // a careful slow drag), so it cleanly separates the two without
  // either getting trapped in noise or accidentally releasing
  // mid-drag. Engagement is still strictly positional (cursor must
  // leave the dz), so this can't fire as the old "velocity bypass"
  // did against a hover-inside-dz.
  static const double _cursorAtRestPxPerSec = 80.0;

  /// Last computed focal. Exposed for the debug HUD that draws the
  /// focal as a hollow yellow ring.
  Offset? get smoothedFocal => _smoothedFocal;

  /// Whether the bounded-mode deadzone gate is currently bypassed
  /// because the spring is mid-chase. Exposed for the debug HUD so
  /// we can see, frame by frame, whether the camera is "tracking" or
  /// "holding". When the camera is unexpectedly drifting, this tells
  /// us whether the gate latched (true → controller thinks the
  /// cursor left the deadzone at some point) or whether the drift is
  /// coming from somewhere else (false → the spring shouldn't be
  /// moving at all).
  bool get inFlight => _inFlight;

  /// Current spring velocity in source-video pixels per second.
  /// Exposed for the debug HUD.
  Offset get focalVelocity => Offset(_focalVx, _focalVy);

  /// Compute the focal for the current frame.
  ///
  /// Returns `null` when no zoom region is active at [position].
  /// Idempotent for the same set of inputs at the same playhead — a
  /// repeated call with `dt = 0` is a no-op for the spring (no
  /// integration), so settings edits at a paused position take
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
  ///
  /// [cursorVelocity] is the cursor's intrinsic scene velocity (px/s)
  /// at [position]. Used by the bounded-mode gate to decide when an
  /// in-flight chase should release: continuous motion keeps the
  /// chase engaged (no flap at the dz boundary mid-flight), and the
  /// gate only releases once the cursor has come to rest inside the
  /// dz. Pass `Offset.zero` when no velocity is available — the gate
  /// then degrades to pure positional behaviour.
  ZoomFocalUpdate? update({
    required Duration position,
    required List<ZoomRegion> zoomRegions,
    required Offset? cursor,
    required Size videoSize,
    Offset cursorVelocity = Offset.zero,
    bool forceSnap = false,
  }) {
    final activeZoom = _activeZoomAt(position, zoomRegions);
    if (activeZoom == null) {
      _previousActiveZoom = null;
      _smoothedFocal = null;
      _focalVx = 0;
      _focalVy = 0;
      _inFlight = false;
      _exitRampStartFocal = null;
      _lastUpdatePosition = position;
      return null;
    }

    // All-spring policy: there are no instantaneous camera teleports.
    // The only one-time "init" left is the very first frame after the
    // controller has no focal at all — we have to park the spring
    // *somewhere* before it can chase. We park it at the zoom rect's
    // centre because at the moment of init the zoom factor is still 1
    // (we're at the very start of the enter ramp); the focal at
    // zoom=1 is visually invisible (the camera is in identity-
    // transform mode), so this "snap" produces no perceptible jump.
    // As the enter ramp scales the zoom factor up, the camera
    // smoothly zooms in centred on rect.center — which is the
    // framing the user intended when they drew the rect. The gate
    // then decides each frame whether to spring-chase the cursor
    // (cursor outside dz around the focal) or hold.
    if (_smoothedFocal == null) {
      _smoothedFocal = activeZoom.rect.center;
      _focalVx = 0;
      _focalVy = 0;
      _inFlight = false;
      _exitRampStartFocal = null;
      _previousActiveZoom = activeZoom;
      _lastUpdatePosition = position;
      _lastSnapReason = 'init';
      _lastSnapAt = position;
      return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
    }
    // Adopt the new zoom instance without resetting any spring state.
    // Structural edits (followCursor toggle, followMode change, rect
    // drag, zoom region timeline-slot change) flow into the gate's
    // target on the next spring step and the spring chases there —
    // no jolt, no snap, just smooth motion.
    _previousActiveZoom = activeZoom;

    // Backward scrub or hover-scrub force-snap: don't teleport the
    // focal, but DO zero the spring's velocity. Without zeroing, the
    // stale momentum from before the discontinuity would carry into
    // the post-jump spring step and pull the focal in the wrong
    // direction; with zeroing, the spring restarts from rest at the
    // current focal and accelerates toward the new frame's target.
    // The 200 ms reverse-scrub floor still applies — sub-200 ms
    // backward jitter (typical hover-scrub commits) is ignored as
    // playback noise.
    final reverseScrub = _lastUpdatePosition != null &&
        _lastUpdatePosition!.inMicroseconds - position.inMicroseconds >
            _reverseScrubMinMicros;
    if (forceSnap || reverseScrub) {
      _focalVx = 0;
      _focalVy = 0;
      _inFlight = false;
      _lastSnapReason = forceSnap ? 'forceSnap (vel→0)' : 'reverseScrub (vel→0)';
      _lastSnapAt = position;
    }

    final prevPosition = _lastUpdatePosition;
    _lastUpdatePosition = position;

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
        // Zero velocity AND in-flight state so a post-exit re-entry
        // doesn't carry stale momentum or a stale chase flag from
        // before the ramp.
        _focalVx = 0;
        _focalVy = 0;
        _inFlight = false;
        return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
      }
    }
    // Outside the exit ramp — clear the captured anchor so the next
    // entry into an exit ramp re-captures from a fresh position.
    _exitRampStartFocal = null;

    // Resolve target this frame. The bounded-mode gate is
    // velocity-aware: it engages when the cursor leaves the
    // deadzone, and releases only once the cursor has come to rest
    // inside the deadzone — see [_resolveTarget] for the why.
    final baseTarget = _baseTarget(activeZoom, cursor);
    final target = _resolveTarget(
      zoom: activeZoom,
      cursor: cursor,
      cursorVelocity: cursorVelocity,
      baseTarget: baseTarget,
      currentFocal: _smoothedFocal!,
      videoSize: videoSize,
    );

    // Step the spring.
    final followUs = activeZoom.followDuration.inMicroseconds;
    if (prevPosition == null || followUs <= 0) {
      // No previous frame to measure dt against, or the user has dialed
      // [followDuration] to zero (snap mode). Either way: jump to
      // target and zero velocity. Same first-frame and snap-mode
      // semantics as before.
      _smoothedFocal = target;
      _focalVx = 0;
      _focalVy = 0;
    } else {
      var dtMicros = position.inMicroseconds - prevPosition.inMicroseconds;
      if (dtMicros > 0) {
        if (dtMicros > _maxTotalDtMicros) dtMicros = _maxTotalDtMicros;
        final numSteps =
            (dtMicros / _maxSubStepMicros).ceil().clamp(1, 1 << 20);
        final subDtMicros = dtMicros / numSteps;
        final subDt = subDtMicros / 1e6;
        final settleSeconds = followUs / 1e6;
        final omega = 2.0 / settleSeconds;
        final k = omega * omega;
        // Damping ratio: critical (ζ = 1, c = 2ω) when the spring is
        // chasing — smooth acceleration to the target with no
        // overshoot. Overdamped (ζ = 3, c = 6ω) when the bounded gate
        // has locked the target to the current focal — any residual
        // chase velocity at the chase→hold transition then bleeds
        // off ~3× faster, so the focal doesn't coast visibly past
        // the cursor's re-entry point (the "trailing flick" complaint).
        // We detect "hold mode" by target equality with the focal —
        // `_resolveTarget` returns `currentFocal` itself in that case.
        final isHolding = target == _smoothedFocal;
        final c = isHolding ? 6.0 * omega : 2.0 * omega;
        var x = _smoothedFocal!.dx;
        var y = _smoothedFocal!.dy;
        var vx = _focalVx;
        var vy = _focalVy;
        for (var i = 0; i < numSteps; i++) {
          final ax = -k * (x - target.dx) - c * vx;
          final ay = -k * (y - target.dy) - c * vy;
          vx += ax * subDt;
          vy += ay * subDt;
          x += vx * subDt;
          y += vy * subDt;
        }
        _smoothedFocal = Offset(x, y);
        _focalVx = vx;
        _focalVy = vy;
      }
      // dtMicros == 0 → same-position re-evaluation. Don't integrate;
      // return the current focal so settings edits at a paused
      // playhead are reflected without phantom motion.
    }

    return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
  }

  /// Drop all smoothing state. Use when switching to a different
  /// recording, scrubbing past a zoom region, or in tests.
  void reset() {
    _previousActiveZoom = null;
    _smoothedFocal = null;
    _focalVx = 0;
    _focalVy = 0;
    _inFlight = false;
    _exitRampStartFocal = null;
    _lastUpdatePosition = null;
  }

  // --- internals --------------------------------------------------

  // [_isFreshZoom] removed: the all-spring policy means we no longer
  // distinguish "structural edit" from "non-structural edit" at the
  // gate level — every change flows through the spring as a chase.
  // The only initialization path is the `_smoothedFocal == null`
  // branch in [update], handled inline.

  /// Exit ramp window for [zoom] in microseconds-into-region — the
  /// last [ZoomRegion.exitDuration] post-squeeze when enter+exit
  /// exceed the region length. Returns null when there's no exit
  /// ramp to enter (zero-length region or zero exit duration).
  static ({int exitStartUs, int exitUs})? _exitRampWindow(ZoomRegion zoom) {
    final regionUs = zoom.duration.inMicroseconds;
    if (regionUs <= 0) return null;

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
    if (exitUs <= 0) return null;
    final exitStartUs = regionUs - exitUs;
    return (exitStartUs: exitStartUs, exitUs: exitUs);
  }

  // [_initialTarget] removed: the spring now always starts at
  // videoCenter on a cold init and chases the gate's target. The
  // gate (in [_resolveTarget]) is the single source of truth for
  // where the focal *should* be on any given frame.

  /// "Base" target this frame, ignoring the deadzone — the cursor
  /// when we're following it, or the zoom's static center otherwise.
  static Offset _baseTarget(ZoomRegion zoom, Offset? cursor) {
    if (!zoom.followCursor || cursor == null) {
      return zoom.rect.center;
    }
    return cursor;
  }

  /// Decide the spring target this frame.
  ///
  /// For non-bounded modes (centered / predictive / followCursor=off)
  /// the target is whatever [_baseTarget] returned — no gating.
  ///
  /// For bounded mode the gate is **engage-positional, release-
  /// velocity-aware**:
  ///   - **Engagement** (when not currently chasing): cursor outside
  ///     the deadzone ⇒ start chasing. Strictly positional, so a
  ///     hovering cursor with jitter inside the dz never starts a
  ///     chase from noise alone.
  ///   - **Release** (when currently chasing): cursor must be **both**
  ///     inside the deadzone **and** at rest (scene-velocity below
  ///     [_cursorAtRestPxPerSec]). The velocity condition is what
  ///     prevents the gate-cycle artefact that pure-positional gates
  ///     produce against a continuously-moving cursor — see the
  ///     comment on [_cursorAtRestPxPerSec] for the full diagnosis.
  ///
  /// [_inFlight] holds across frames as a result, but only across
  /// the duration of a single chase. It is NOT the old "commit-to-
  /// chase" latch: engagement remains gated by the cursor genuinely
  /// leaving the dz.
  Offset _resolveTarget({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset cursorVelocity,
    required Offset baseTarget,
    required Offset currentFocal,
    required Size videoSize,
  }) {
    final boundsActive = zoom.followCursor &&
        zoom.followMode == FollowMode.bounded &&
        cursor != null &&
        zoom.deadzoneRatio > 0 &&
        videoSize.width > 0 &&
        videoSize.height > 0;
    if (!boundsActive) {
      _inFlight = false;
      return baseTarget;
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
      // Currently chasing. Release only when the cursor is **both**
      // inside the dz **and** at rest. The velocity check is what
      // keeps a continuous chase from cycling: during steady motion
      // the spring's lag puts the cursor inside the dz, but the
      // cursor's intrinsic velocity is well above the threshold so
      // the gate stays engaged. When the user actually stops moving
      // the cursor, scene velocity falls within ~33 ms of the stop
      // (the velocity-lookback window) and the gate releases here.
      final cursorAtRest =
          cursorVelocity.distance < _cursorAtRestPxPerSec;
      if (cursorAtRest && dz.contains(cursor)) {
        _inFlight = false;
        return currentFocal;
      }
      return baseTarget;
    }

    // Not currently chasing. Engagement is strictly positional so
    // hover jitter inside the dz never starts a chase from noise.
    if (dz.contains(cursor)) {
      return currentFocal;
    }
    _inFlight = true;
    return baseTarget;
  }

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
