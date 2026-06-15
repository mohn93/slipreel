import 'dart:math' as math;

import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart' show Offset, Size;
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/follow_strategy.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';

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
  ZoomFocalController({MotionTuning? tuning})
      : tuning = tuning ?? MotionTuning.defaults;

  /// Motion-feel tuning (reverse-scrub floor, sub-step caps, the
  /// bounded-mode at-rest velocity threshold). Defaults to the
  /// historic hand-tuned production set. Mutable so a preset picker
  /// or JSON-reload can swap it at runtime without recreating the
  /// controller (spring state is preserved — the next update() reads
  /// the new constants).
  MotionTuning tuning;
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

  /// Per-mode target resolution lives in [FollowStrategy]. Cached by
  /// [FollowMode] so the bounded gate's `_inFlight` persists across
  /// frames within one zoom region. Reset on active-region change.
  final Map<FollowMode, FollowStrategy> _strategies = {};
  FollowMode? _activeStrategyMode;

  FollowStrategy _strategyFor(FollowMode mode) =>
      _strategies.putIfAbsent(mode, () => followStrategyFor(mode));

  // Last [position] passed to [update]. Used for two purposes:
  // (1) detect backward scrubs that should snap rather than integrate;
  // (2) compute `dt` for the spring step.
  Duration? _lastUpdatePosition;

  // Focal at the moment the exit ramp started. Captured once on the
  // first frame inside the exit ramp; cleared whenever the controller
  // leaves the exit ramp so the next exit captures fresh.
  Offset? _exitRampStartFocal;

  // Focal at the moment the enter ramp started (captured on the first
  // enter-ramp frame): rect.center for a followCursor zoom, the video
  // center for a manual (followCursor:false) placement — see the enter-ramp
  // anchor comment in [update] for why the two differ. Cleared when the
  // controller leaves the enter window so a re-entry re-captures.
  Offset? _enterRampStartFocal;

  // Back-load exponent for the entry pan relative to the zoom-scale ramp.
  // The pan and the scale share the same window and curve, so they finish
  // at the same instant mathematically — but a settling position reads as
  // "arrived" while it's still a few pixels out, whereas the magnification
  // stays visibly in motion through the curve's tail. Equal progress
  // therefore *looks* like the pan reaches the cursor before the zoom
  // finishes. Raising the eased pan progress to this exponent holds the
  // focal nearer rect.center through the middle of the ramp and closes the
  // last of the distance as the zoom completes, so the two land together
  // perceptually. 1.0 == exact lock-step; larger == more back-loaded.
  //
  // This is the FOLLOWCURSOR back-load (pan rect.center -> cursor). The
  // manual-placement enter pan (center -> placement) uses the live-tunable
  // MotionTuning.manualEntryPanBackload instead — its geometry reads as
  // synced at lock-step (1.0), unlike the cursor case.
  static const double _entryPanBackload = 2.0;

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
  int get _reverseScrubMinMicros => tuning.reverseScrubFloor.inMicroseconds;

  // Largest sub-step the spring is integrated over. Semi-implicit
  // Euler is stable for damped-spring systems while `c·dt < 2`; for
  // the minimum allowed settleTime (100 ms) `c = 4/T = 40`, so
  // `dt < 50 ms`. 16 ms (one 60 fps frame) keeps the integration
  // well inside that band for every supported [ZoomRegion.followDuration].
  int get _maxSubStepMicros => tuning.subStepCapMicros.inMicroseconds;

  // Hard cap on the *total* dt fed into a single update. After a
  // pause-resume the next call may carry a multi-second gap; capping
  // at 250 ms keeps sub-step counts bounded (≤16 sub-steps) and the
  // spring effectively jumps to the new state on the following frame.
  int get _maxTotalDtMicros => tuning.dtCap.inMicroseconds;

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
  //
  // The threshold itself now lives on [MotionTuning] and is read by
  // [BoundedFollowStrategy].

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
  bool get inFlight {
    final mode = _activeStrategyMode;
    if (mode == null) return false;
    return _strategies[mode]?.inFlight ?? false;
  }

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
    ZoomRegion? activeRegionOverride,
    Curve screenRampCurve = Curves.easeInOutQuad,
  }) {
    final activeZoom =
        activeRegionOverride ?? _activeZoomAt(position, zoomRegions);
    if (activeZoom == null) {
      _smoothedFocal = null;
      _focalVx = 0;
      _focalVy = 0;
      _resetStrategies();
      _exitRampStartFocal = null;
      _enterRampStartFocal = null;
      _lastUpdatePosition = position;
      return null;
    }

    // Resolved ramp curve for this region's enter/exit focal lock-step.
    // Mirrors the scale's resolution at the render call sites:
    // per-region override wins, else the project's screen ramp curve.
    final rampCurve =
        activeZoom.rampCurveOverride?.toFlutterCurve() ?? screenRampCurve;

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
      _resetStrategies();
      _exitRampStartFocal = null;
      _enterRampStartFocal = null;
      _lastUpdatePosition = position;
      _lastSnapReason = 'init';
      _lastSnapAt = position;
      _activeStrategyMode = activeZoom.followMode;
      return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
    }
    // Adopt the new zoom instance without resetting any spring state.
    // Structural edits (followCursor toggle, followMode change, rect
    // drag, zoom region timeline-slot change) flow into the gate's
    // target on the next spring step and the spring chases there —
    // no jolt, no snap, just smooth motion.

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
      _resetStrategies();
      _lastSnapReason = forceSnap ? 'forceSnap (vel→0)' : 'reverseScrub (vel→0)';
      _lastSnapAt = position;
    }

    // Placement-picker preview: when a caller injects an override AND
    // asks for forceSnap, teleport the focal to the override's
    // rect.center directly. Without this, the spring would have to
    // integrate over many frames to chase the new target — fine when
    // playing (frames keep arriving) but invisible while paused (no
    // frame loop). Returning the override frame here keeps the camera
    // glued to the dragged rect even when the video is paused.
    if (forceSnap && activeRegionOverride != null) {
      _smoothedFocal = activeRegionOverride.rect.center;
      _focalVx = 0;
      _focalVy = 0;
      _lastSnapReason = 'forceSnap+override (teleport)';
      _lastSnapAt = position;
      return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
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
        final eased = rampCurve.transform(tNorm.toDouble());
        final centre = Offset(videoSize.width / 2, videoSize.height / 2);
        _smoothedFocal = Offset.lerp(_exitRampStartFocal, centre, eased);
        // Zero velocity AND in-flight state so a post-exit re-entry
        // doesn't carry stale momentum or a stale chase flag from
        // before the ramp.
        _focalVx = 0;
        _focalVy = 0;
        _resetStrategies();
        // Clear the enter anchor here too: a no-hold region (enter window
        // immediately followed by exit window) returns from the exit branch
        // every frame and would otherwise never hit the outside-enter-window
        // clear below, leaking this region's anchor into the NEXT region.
        _enterRampStartFocal = null;
        return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
      }
    }
    // Outside the exit ramp — clear the captured anchor so the next
    // entry into an exit ramp re-captures from a fresh position.
    _exitRampStartFocal = null;

    // Enter ramp: pan rect.center -> cursor in lock-step with the zoom-in
    // scale (same window, same resolved curve), symmetric to the exit ramp
    // above. The focal reaches the cursor exactly as magnification reaches
    // full, then the spring takes over for steady-state follow.
    //
    // Runs BEFORE the per-mode strategy resolve, with DETERMINISTIC,
    // gate-independent endpoints, so the live spring path, the
    // DeterministicFocalTrack replay (scrub / paused / scene-blur), and the
    // export pipeline all produce a byte-identical pan:
    //   * anchor at activeZoom.rect.center — NOT `_smoothedFocal`, which on a
    //     PERSISTENT controller crossing back-to-back regions is the prior
    //     region's leftover focal (its exit ramp left it at ~video-center),
    //     so the live pan would start ~video-center while the fresh-controller
    //     track starts at rect.center — a ~700px play-vs-scrub divergence.
    //   * aim at the raw cursor destination — NOT the bounded strategy's
    //     deadzone-gated target. The gate's per-frame hold/chase flip swaps
    //     the lerp endpoint, and because the ramp writes position directly
    //     (no spring integration to absorb it) that became a 150-430px
    //     single-frame teleport whenever the cursor moved during zoom-in.
    // The bounded gate is a steady-state concept; it re-engages cleanly on
    // the first post-ramp spring frame (resolve runs below).
    //
    // The spring is also held at REST for the whole ramp: a non-zero handoff
    // velocity made the critically-damped spring sail PAST the cursor once
    // (overshoot, magnified by the zoom). Zero velocity hands it a clean
    // at-rest state on the cursor.
    final enter = _enterRampWindow(activeZoom);
    if (enter != null) {
      final tIntoRegionUs =
          position.inMicroseconds - activeZoom.startTime.inMicroseconds;
      // Inclusive of the exact ramp end (`<=`): at `tIntoRegion == enterUs`
      // the scale has just reached full zoom (its enter formula switches to
      // the hold at the same instant), so emitting `panEased(1) == 1` here
      // lands the focal exactly on the cursor as magnification completes,
      // with no sub-frame residual for the spring to mop up. The exit ramp
      // is checked earlier and returns first, so a no-hold (enter==exit
      // boundary) region can't double-handle this frame.
      if (tIntoRegionUs >= 0 && tIntoRegionUs <= enter.enterUs) {
        // Anchor the enter pan at the honest z=1 framing.
        //   * followCursor: the region's rect.center — the framing the user
        //     drew, which the pan then leaves to chase the cursor.
        //   * MANUAL (followCursor:false): the pan's only destination IS
        //     rect.center, so anchoring there leaves the lerp below FLAT and
        //     hands the entire visible pan to ZoomTransformer's per-frame
        //     bounds clamp — a 1/z curve that FRONT-LOADS the pan ahead of the
        //     eased scale (camera lunges to the corner, then the magnification
        //     catches up; the "zoom-then-slide" the manual placement showed).
        //     Anchoring at the video center instead lets the back-loaded lerp
        //     trace the pan center->placement IN STEP with the scale. Proven:
        //     lerp(center, fullZoomClampedTarget, eased^_entryPanBackload)
        //     stays at/under the per-frame clamp for all t and any zoomLevel
        //     (equality only at the endpoints), so the transformer never
        //     re-clamps it and cannot front-load. Deterministic (pure fn of
        //     videoSize) — play == scrub == export parity holds.
        final enterAnchor = activeZoom.followCursor
            ? activeZoom.rect.center
            : Offset(videoSize.width / 2, videoSize.height / 2);
        _enterRampStartFocal ??= enterAnchor;
        final rawTarget = (activeZoom.followCursor && cursor != null)
            ? cursor
            : activeZoom.rect.center;
        // Aim the pan at what the FULL zoom level can actually frame, not
        // the raw cursor. An edge cursor (or an edge-hugging rect.center)
        // sits beyond the reachable focal range, so lerping toward the raw
        // point makes the eased focal cross the *current-frame* bound
        // partway through the ramp — at which point ZoomTransformer pins the
        // viewport to the video edge and the pan visibly finishes while the
        // magnification is still growing. Clamping the target to the
        // full-zoom bound (same formula the transformer applies at paint)
        // keeps the back-loaded focal at/under the per-frame clamp the whole
        // way, so the pan lands on the edge exactly as the zoom completes.
        // Pure function of (cursor/rect, videoSize, zoomLevel) — play ==
        // scrub == export stays byte-identical.
        final entryTarget = ZoomTransformer.clampFocalToBounds(
            rawTarget, videoSize, activeZoom.zoomLevel);
        final tNorm =
            (tIntoRegionUs / enter.enterUs).clamp(0.0, 1.0).toDouble();
        // Clamp before the back-load pow: a custom bezier ramp curve can
        // overshoot <0 or >1, and pow() of a negative base with a
        // non-integer exponent is NaN.
        final eased = rampCurve.transform(tNorm).clamp(0.0, 1.0);
        // followCursor pans rect.center -> cursor and uses the fixed
        // back-load tuned for that geometry. A MANUAL placement pans
        // center -> placement and reads as synced at lock-step (1.0,
        // mirroring the exit ramp); its exponent is live-tunable via
        // MotionTuning.manualEntryPanBackload so the feel can be dialed
        // without a rebuild.
        final backload = activeZoom.followCursor
            ? _entryPanBackload
            : tuning.manualEntryPanBackload;
        final panEased = math.pow(eased, backload).toDouble();
        final newFocal =
            Offset.lerp(_enterRampStartFocal, entryTarget, panEased)!;
        _focalVx = 0;
        _focalVy = 0;
        _smoothedFocal = newFocal;
        return ZoomFocalUpdate(zoom: activeZoom, focal: newFocal);
      }
    }
    // Outside the enter window — clear the anchor so a re-entry into an
    // enter ramp re-captures from a fresh position.
    _enterRampStartFocal = null;

    // Resolve target this frame via the pluggable per-mode strategy.
    // The bounded strategy owns its gate state; centered/predictive
    // are stateless pass-throughs. The strategy also reports whether
    // the controller should treat this frame as a hold (overdamped)
    // or an active chase (critical damping) — replaces the fragile
    // `target == _smoothedFocal` check.
    final strategy = _strategyFor(activeZoom.followMode);
    _activeStrategyMode = activeZoom.followMode;
    final resolution = strategy.resolve(
      zoom: activeZoom,
      cursor: cursor,
      cursorVelocity: cursorVelocity,
      currentFocal: _smoothedFocal!,
      videoSize: videoSize,
      tuning: tuning,
    );
    final target = resolution.target;
    final isHolding = resolution.isHolding;

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
        // overshoot. Overdamped (ζ = 3, c = 6ω) when the gate has
        // locked the target to the current focal — any residual
        // chase velocity at the chase→hold transition then bleeds
        // off ~3× faster, so the focal doesn't coast visibly past
        // the cursor's re-entry point (the "trailing flick"
        // complaint). Hold detection comes from the strategy's
        // explicit flag instead of a fragile Offset== compare.
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
    _smoothedFocal = null;
    _focalVx = 0;
    _focalVy = 0;
    _resetStrategies();
    _exitRampStartFocal = null;
    _enterRampStartFocal = null;
    _lastUpdatePosition = null;
  }

  void _resetStrategies() {
    for (final s in _strategies.values) {
      s.reset();
    }
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

  /// Enter ramp window for [zoom] in microseconds — the first
  /// [ZoomRegion.enterDuration], proportionally squeezed (matching
  /// [ZoomTransformer._calculateZoomFactor]) when enter+exit overflow the
  /// region. Returns null when there's no enter ramp (zero-length region
  /// or zero enter duration).
  static ({int enterUs})? _enterRampWindow(ZoomRegion zoom) {
    final regionUs = zoom.duration.inMicroseconds;
    if (regionUs <= 0) return null;
    var enterUs = zoom.enterDuration.inMicroseconds;
    final exitUs = zoom.exitDuration.inMicroseconds;
    final totalRamp = enterUs + exitUs;
    if (totalRamp > regionUs && totalRamp > 0) {
      final scale = regionUs / totalRamp;
      enterUs = (enterUs * scale).round();
    }
    if (enterUs <= 0) return null;
    return (enterUs: enterUs);
  }

  // _baseTarget and _resolveTarget moved into FollowStrategy
  // (P1-5). The controller is now a pure spring integrator that
  // delegates per-frame target resolution to a pluggable strategy
  // keyed by FollowMode.

  // Closed-end lookup: includes `position == endTime` so the focal
  // controller still emits the exit-ramp completion frame (zoom factor
  // at 1.0×, focal at video centre). Delegates to [ZoomRegion.activeAt]
  // so all engine call sites share one definition of "active zoom at t".
  static ZoomRegion? _activeZoomAt(
    Duration position,
    List<ZoomRegion> zoomRegions,
  ) =>
      ZoomRegion.activeAt(position, zoomRegions);
}

/// Result of a [ZoomFocalController.update] call when a zoom is active.
class ZoomFocalUpdate {
  const ZoomFocalUpdate({required this.zoom, required this.focal});
  final ZoomRegion zoom;
  final Offset focal;
}
