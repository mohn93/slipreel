import 'dart:math' as math;

import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart' show Offset, Size;
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/follow_strategy.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

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
  bool? _exitRampStartReachable;

  // Focal at the moment the enter ramp started. Manual placements start at the
  // video center and pan to rect.center. Auto-follow also starts at the video
  // center and pans to the cursor; the region rect may contain stale manual
  // placement and must not steer a followCursor zoom.
  Offset? _enterRampStartFocal;

  // Pan TARGET captured once on the first enter-ramp frame, tied to the same
  // lifecycle as [_enterRampStartFocal]. For a manual placement this is just
  // rect.center (already stable). For a followCursor zoom this is the cursor
  // target, never rect.center.
  Offset? _enterRampTarget;

  // Full-zoom-clamped focal target emitted by the enter ramp. Preserved across
  // the enter->hold boundary for followCursor zooms so the first hold frame can
  // distinguish a genuinely new cursor move from the smoothed cursor sprite
  // still catching up to a parked raw cursor.
  Offset? _enterRampFocalTarget;

  // Transitional hold target immediately after a followCursor enter ramp. When
  // the raw cursor is already parked at the enter target but the smoothed sprite
  // is still lagging behind, the normal hold strategy would chase that lagging
  // sprite and visibly yank the camera away from the just-landed enter focal.
  // Holding the painted enter target until the sprite reaches the same
  // full-zoom clamped basin removes that handoff detour. Cleared as soon as the
  // raw cursor starts moving again, the sprite catches up, or the zoom exits.
  Offset? _postEnterHoldTarget;

  // Last cursor sample that fell inside the video frame. On multi-monitor
  // recordings the cursor moves onto another display and is recorded with
  // out-of-bounds (often negative) coordinates; rather than chase the camera
  // off-screen, we freeze the follow target here until the cursor returns
  // in-bounds. Null until the first in-bounds sample of the active region;
  // reset whenever the controller leaves the region.
  Offset? _lastInBoundsCursor;

  // Default manual-placement enter-pan back-load as a function of zoom
  // level, from hand-tuned sweet spots. A lower exponent lets the pan lead
  // the zoom more (reads as synced at lower magnifications where the
  // reachable framing is tight); the decline STEEPENS past 2× — 0.76, 0.63,
  // 0.26 is not linear — so the relationship is a piecewise-linear curve
  // through the measured points rather than one line (a line mis-fit the
  // upper range). Below/above the measured band the nearest endpoint holds.
  // Extend [_manualBackloadPoints] as higher-zoom points are measured. A
  // manual regions' [ZoomRegion.manualPanBackload] override takes precedence.
  // Follow-cursor regions reuse the zoom-level curve, but ignore any stale
  // manual override stored on the region.
  //
  // (zoomLevel, backload), sorted ascending by zoomLevel. 5.0 is the max
  // zoomLevel (ZoomRegion clamps 1..5) and tuned to 0.0 — at max zoom the
  // pan rides the bounds clamp from the first frame (the original
  // clamp-driven front-load), which reads right there. 3–4× is currently
  // linear interpolation between the 2.5× and 5.0× anchors (not directly
  // measured); add points here if that band needs shaping.
  static const List<(double, double)> _manualBackloadPoints = [
    (1.5, 0.76),
    (2.0, 0.63),
    (2.5, 0.26),
    (5.0, 0.0),
  ];

  /// The default manual enter-pan back-load exponent for [zoomLevel],
  /// piecewise-linearly interpolated through [_manualBackloadPoints] and
  /// clamped flat outside the measured range. Public so the editor can show
  /// the computed default next to the per-zoom override slider.
  static double manualBackloadForZoom(double zoomLevel) {
    const pts = _manualBackloadPoints;
    if (zoomLevel <= pts.first.$1) return pts.first.$2;
    if (zoomLevel >= pts.last.$1) return pts.last.$2;
    for (var i = 0; i < pts.length - 1; i++) {
      final (z1, b1) = pts[i + 1];
      if (zoomLevel <= z1) {
        final (z0, b0) = pts[i];
        return b0 + (b1 - b0) * ((zoomLevel - z0) / (z1 - z0));
      }
    }
    return pts.last.$2; // unreachable (guarded above)
  }

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
    double rampDurationScale = 1.0,

    /// For a followCursor zoom, the SETTLE target for the enter pan: the
    /// (raw) cursor position at the end of the enter ramp — i.e. where the
    /// cursor will be once the zoom is fully in. The enter pans straight
    /// here instead of chasing the lagging SMOOTHED cursor's catch-up path
    /// (which read as "the zoom goes to the wrong spot then slides to the
    /// cursor"). Null ⇒ fall back to the live cursor / base focal.
    Offset? enterCursorTarget,

    /// Device-bezel framing that routes all focal clamps through the canvas
    /// geometry. Null ⇒ identity framing ⇒ byte-identical to the legacy
    /// behavior (clamps stay inside the source-video bounds).
    ZoomFraming? framing,
  }) {
    final activeZoom =
        activeRegionOverride ?? _activeZoomAt(position, zoomRegions);
    if (activeZoom == null) {
      _smoothedFocal = null;
      _focalVx = 0;
      _focalVy = 0;
      _resetStrategies();
      _exitRampStartFocal = null;
      _exitRampStartReachable = null;
      _enterRampStartFocal = null;
      _enterRampTarget = null;
      _enterRampFocalTarget = null;
      _postEnterHoldTarget = null;
      _lastInBoundsCursor = null;
      _lastUpdatePosition = position;
      return null;
    }

    final fr = framing ?? ZoomFraming.identity(videoSize);

    // Off-screen cursor freeze: on multi-monitor recordings the cursor moves
    // onto another display and is recorded out of the video frame (often
    // negative). Don't chase the camera off-screen — substitute the last
    // in-bounds cursor so the follow target FREEZES where the cursor left the
    // frame, and resumes live tracking the moment it returns in-bounds. Runs
    // before every cursor consumer below (enter pan, hold handoff, strategy).
    if (cursor != null) {
      if (_inBounds(cursor, videoSize)) {
        _lastInBoundsCursor = cursor;
      } else {
        cursor = _lastInBoundsCursor;
      }
    }

    // Resolved ramp curve for this region's enter/exit focal lock-step.
    // Mirrors the scale's resolution at the render call sites:
    // per-region override wins, else the project's screen ramp curve.
    final rampCurve =
        activeZoom.rampCurveOverride?.toFlutterCurve() ?? screenRampCurve;

    // All-spring policy: there are no instantaneous camera teleports.
    // The only one-time "init" left is the very first frame after the
    // controller has no focal at all — we have to park the spring
    // *somewhere* before it can chase. Manual placements park at the zoom
    // rect's centre. Auto-follow parks at the video centre because any
    // existing rect is only stale/manual placement metadata once
    // followCursor is enabled; it must not steer the camera.
    if (_smoothedFocal == null) {
      _smoothedFocal = _baseFocal(activeZoom, videoSize);
      _focalVx = 0;
      _focalVy = 0;
      _resetStrategies();
      _exitRampStartFocal = null;
      _exitRampStartReachable = null;
      _enterRampStartFocal = null;
      _enterRampTarget = null;
      _enterRampFocalTarget = null;
      _postEnterHoldTarget = null;
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

    // Manual placement: magnify-in-place. The focal is the placement center
    // for the entire region; the zoom transform's (1 − 1/z) translation
    // produces the enter/exit pan from the scale ramp, so the pan is
    // structurally synced and the placement never lurches across zoom-level
    // changes. No spring, no clamp, no back-load. activeZoom is the override
    // when one is supplied (placement-picker drag), so this also keeps the
    // camera glued to the dragged rect while paused — subsuming the old
    // forceSnap+override manual case. The enter/exit/spring logic below is
    // therefore FOLLOW-CURSOR-ONLY.
    if (!activeZoom.followCursor) {
      final focal = _baseFocal(activeZoom, videoSize); // == rect.center
      _smoothedFocal = focal;
      _focalVx = 0;
      _focalVy = 0;
      _resetStrategies();
      _exitRampStartFocal = null;
      _exitRampStartReachable = null;
      _enterRampStartFocal = null;
      _enterRampTarget = null;
      _enterRampFocalTarget = null;
      _postEnterHoldTarget = null;
      _lastUpdatePosition = position;
      return ZoomFocalUpdate(zoom: activeZoom, focal: focal);
    }

    // Backward scrub or hover-scrub force-snap: don't teleport the
    // focal, but DO zero the spring's velocity. Without zeroing, the
    // stale momentum from before the discontinuity would carry into
    // the post-jump spring step and pull the focal in the wrong
    // direction; with zeroing, the spring restarts from rest at the
    // current focal and accelerates toward the new frame's target.
    // The 200 ms reverse-scrub floor still applies — sub-200 ms
    // backward jitter (typical hover-scrub commits) is ignored as
    // playback noise.
    final reverseScrub =
        _lastUpdatePosition != null &&
        _lastUpdatePosition!.inMicroseconds - position.inMicroseconds >
            _reverseScrubMinMicros;
    if (forceSnap || reverseScrub) {
      _focalVx = 0;
      _focalVy = 0;
      _resetStrategies();
      _lastSnapReason = forceSnap
          ? 'forceSnap (vel→0)'
          : 'reverseScrub (vel→0)';
      _lastSnapAt = position;
    }

    // Placement-picker preview: when a caller injects an override AND
    // asks for forceSnap, teleport the focal to the override's base focal
    // directly. Without this, the spring would have to
    // integrate over many frames to chase the new target — fine when
    // playing (frames keep arriving) but invisible while paused (no
    // frame loop). Returning the override frame here keeps the camera
    // glued to the override even when the video is paused.
    //
    // Only follow-cursor overrides reach here — a manual override returns
    // from the magnify-in-place branch above, so `_baseFocal` resolves to
    // the video center for the follow-cursor case that remains.
    if (forceSnap && activeRegionOverride != null) {
      _smoothedFocal = _baseFocal(activeRegionOverride, videoSize);
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
    final exit = _exitRampWindow(activeZoom, rampDurationScale);
    if (exit != null) {
      final tIntoRegionUs =
          position.inMicroseconds - activeZoom.startTime.inMicroseconds;
      if (tIntoRegionUs >= exit.exitStartUs) {
        final centre = Offset(videoSize.width / 2, videoSize.height / 2);
        // Capture the exit-start anchor as the VISIBLE focal. For edge
        // placements/cursors the hold-phase spring can sit outside the
        // full-zoom box, while the transformer paints the per-axis-clamped
        // point; capturing the painted point removes a one-frame hold->exit
        // jump.
        _exitRampStartFocal ??= fr.clampFocal(
          _smoothedFocal!,
          activeZoom.zoomLevel,
        );
        _exitRampStartReachable ??=
            (fr.clampFocal(
                      _smoothedFocal!,
                      activeZoom.zoomLevel,
                    ) -
                    _smoothedFocal!)
                .distance <
            0.5;
        final tIntoExit = (tIntoRegionUs - exit.exitStartUs).clamp(
          0,
          exit.exitUs,
        );
        final tNorm = exit.exitUs == 0 ? 1.0 : tIntoExit / exit.exitUs;
        // Same curve the ZoomTransformer applies to the zoom factor
        // (its rampCurve default). Keeping these in lock-step is what
        // makes the recenter feel like part of the zoom-out instead
        // of a separate motion.
        final eased = rampCurve.transform(tNorm.toDouble());
        // Mirror the enter pan on the way out. The enter places the focal at
        // fraction `zoomInProgress^backload` from center toward the
        // cursor target; during exit the zoom-in progress runs 1->0 as
        // `1 - eased`, so the focal must sit at `(1 - eased)^backload` from
        // center for the zoom-out to be the exact time-reverse of the
        // zoom-in. A fixed lock-step exit (backload 1.0) against a
        // zoom-dependent leading enter is what read as "wrong" by a
        // different amount at each zoom level. Follow-cursor regions use the
        // zoom-level fit but never inherit a stale manual override.
        // (Manual placements magnify-in-place and never reach this ramp; this
        // block is follow-cursor-only.) Reachable (interior) cursors use
        // lock-step (1.0), so the zoom-OUT doesn't ride the video edge before
        // returning to center.
        final exitReachable = _exitRampStartReachable ?? true;
        final exitBackload = exitReachable
            ? 1.0
            : _manualStyleBackload(activeZoom);
        final t01 = exitBackload == 1.0
            ? eased
            : 1.0 -
                  math
                      .pow((1.0 - eased).clamp(0.0, 1.0), exitBackload)
                      .toDouble();
        final lerped = Offset.lerp(_exitRampStartFocal, centre, t01)!;
        // Symmetric with the enter ramp: radially clamp the return so
        // the focal stays on the cursor->center ray (no dog-leg) and inside
        // the current-frame box. z mirrors the enter's, time-reversed:
        // zoom-in progress runs 1 -> 0 across the exit, so z = 1 +
        // (zoomLevel-1)*(1 - eased).
        final z = 1.0 + (activeZoom.zoomLevel - 1.0) * (1.0 - eased);
        _smoothedFocal = fr.clampFocalRadial(
          lerped,
          z,
        );
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
        _enterRampTarget = null;
        _enterRampFocalTarget = null;
        _postEnterHoldTarget = null;
        return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
      }
    }
    // Outside the exit ramp — clear the captured anchor so the next
    // entry into an exit ramp re-captures from a fresh position.
    _exitRampStartFocal = null;
    _exitRampStartReachable = null;

    // Enter ramp: pan base focal -> target in lock-step with the zoom-in
    // scale (same window, same resolved curve), symmetric to the exit ramp
    // above. The focal reaches the cursor exactly as magnification reaches
    // full, then the spring takes over for steady-state follow.
    //
    // Runs BEFORE the per-mode strategy resolve, with DETERMINISTIC,
    // gate-independent endpoints, so the live spring path, the
    // DeterministicFocalTrack replay (scrub / paused / scene-blur), and the
    // export pipeline all produce a byte-identical pan:
    //   * anchor at the base focal — NOT `_smoothedFocal`, which on a
    //     PERSISTENT controller crossing back-to-back regions is the prior
    //     region's leftover focal (its exit ramp left it at ~video-center),
    //     so the live pan would start ~video-center while the fresh-controller
    //     track starts at the base focal — a large play-vs-scrub divergence.
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
    final enter = _enterRampWindow(activeZoom, rampDurationScale);
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
        final videoCentre = Offset(videoSize.width / 2, videoSize.height / 2);
        // Anchor the enter pan at the honest z=1 framing. For followCursor
        // that is always video center; a stale manual rect must not influence
        // auto-follow once the toggle is enabled.
        final enterAnchor = videoCentre;
        _enterRampStartFocal ??= enterAnchor;
        // This block is follow-cursor-only (manual placements return from the
        // magnify-in-place branch above). The live target is the cursor, or
        // the video center as a no-cursor fallback.
        final liveTarget = cursor ?? _baseFocal(activeZoom, videoSize);
        // Capture the pan target ONCE (first enter frame) and hold it for the
        // whole ramp. Prefer the SETTLE target
        // (enterCursorTarget = raw cursor at the enter-ramp end): the enter
        // pans straight to where the cursor ends up, instead of chasing the
        // lagging SMOOTHED cursor's catch-up path (which read as "the zoom
        // goes to the wrong spot below/left then slides to the cursor"). Falls
        // back to the live cursor when no settle target is supplied. Either
        // way it's captured once so a cursor that keeps moving during the ramp
        // doesn't drag the camera around; the hold spring resumes smooth live
        // tracking once the ramp ends.
        _enterRampTarget ??= enterCursorTarget ?? liveTarget;
        final rawTarget = _enterRampTarget!;
        // Aim the pan at what the FULL zoom level can actually frame, not
        // the raw target. An edge cursor sits beyond the reachable focal
        // range, so lerping toward the raw
        // point makes the eased focal cross the *current-frame* bound
        // partway through the ramp — at which point ZoomTransformer pins the
        // viewport to the video edge and the pan visibly finishes while the
        // magnification is still growing. Clamping the target to the
        // full-zoom bound (same formula the transformer applies at paint)
        // keeps the back-loaded focal at/under the per-frame clamp the whole
        // way, so the pan lands on the edge exactly as the zoom completes.
        // Pure function of (cursor/rect, videoSize, zoomLevel) — play ==
        // scrub == export stays byte-identical.
        final entryTarget = fr.clampFocal(
          rawTarget,
          activeZoom.zoomLevel,
        );
        _enterRampFocalTarget = entryTarget;
        // Is the cursor reachable at full zoom (interior), or clamped to
        // the bounds (edge)? A LEADING pan (backload<1) overshoots the small
        // low-zoom box, so the focal rides the box boundary — i.e. the
        // viewport touches the video EDGE — early, then pulls back in to an
        // interior target ("to the edge then back"). For a clamped/EDGE
        // cursor that ride IS the intended motion (it ends at the edge),
        // so the tuned lead is right there. For a reachable INTERIOR
        // cursor, lock-step (backload 1.0) is the fastest pan that
        // provably never exceeds the box (no edge touch) — so use it.
        final reachable = (entryTarget - rawTarget).distance < 0.5;
        final tNorm = (tIntoRegionUs / enter.enterUs)
            .clamp(0.0, 1.0)
            .toDouble();
        // Clamp before the back-load pow: a custom bezier ramp curve can
        // overshoot <0 or >1, and pow() of a negative base with a
        // non-integer exponent is NaN.
        final eased = rampCurve.transform(tNorm).clamp(0.0, 1.0);
        // The zoom-level backload curve (a stale per-region manual override is
        // ignored for follow — see [_manualStyleBackload]).
        final backload = reachable ? 1.0 : _manualStyleBackload(activeZoom);
        final panEased = math.pow(eased, backload).toDouble();
        final newFocal = Offset.lerp(
          _enterRampStartFocal,
          entryTarget,
          panEased,
        )!;
        // Manual-style ramps: a leading pan (backload < 1) walks the focal along the
        // straight center->placement ray FASTER than the zoom grows, so at low
        // z it overshoots the small current-frame reachable box. The
        // transformer's PER-AXIS clamp would then pin one axis and let the
        // other keep moving — bending an off-center/inset placement's path into
        // a dog-leg ("takes some turns before landing"). Clamp RADIALLY here
        // (z = the transformer's own per-frame factor) so the focal stays on
        // the ray AND inside the box; the downstream per-axis clamp is then a
        // no-op for these frames (exact on export/track; the preview badge
        // tween can transiently differ but only ever pulls further in-bounds).
        final z = 1.0 + (activeZoom.zoomLevel - 1.0) * eased;
        final clampedFocal = fr.clampFocalRadial(
          newFocal,
          z,
        );
        _focalVx = 0;
        _focalVy = 0;
        _smoothedFocal = clampedFocal;
        return ZoomFocalUpdate(zoom: activeZoom, focal: clampedFocal);
      }
    }
    // Outside the enter window — clear the anchor + captured target so a
    // re-entry into an enter ramp re-captures from a fresh position.
    //
    // NOTE: this post-enter handoff block is follow-cursor-only. Manual
    // placements return from the magnify-in-place branch near the top of
    // update(), so they never reach here — the `activeZoom.followCursor`
    // guards below (and the handoff hold at line ~691) are effectively
    // always-true at runtime. They are kept explicit as a safety net /
    // documentation; do not assume they ever gate out a manual region here.
    if (activeZoom.followCursor && _enterRampFocalTarget != null) {
      _postEnterHoldTarget ??= _enterRampFocalTarget;
    }
    _enterRampStartFocal = null;
    _enterRampTarget = null;
    _enterRampFocalTarget = null;

    final handoffTarget = _postEnterHoldTarget;
    if (handoffTarget != null && activeZoom.followCursor) {
      final cursorClamped = cursor == null
          ? null
          : fr.clampFocal(
              cursor,
              activeZoom.zoomLevel,
            );
      final cursorCaughtUp =
          cursorClamped != null &&
          (cursorClamped - handoffTarget).distance < 0.5;
      final cursorStillSettling =
          cursorVelocity.distance < tuning.cursorAtRestPxPerSec;
      if (cursorCaughtUp || !cursorStillSettling || cursor == null) {
        _postEnterHoldTarget = null;
      } else {
        _smoothedFocal = handoffTarget;
        _focalVx = 0;
        _focalVy = 0;
        _resetStrategies();
        return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
      }
    } else {
      _postEnterHoldTarget = null;
    }

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
    // Whether the spring was stepped forward this frame. Keep-in-view is a
    // steady-state guard and must not fire on backward-scrub or zero-dt
    // re-evaluation frames (the cursor at those positions is often at a
    // different location than the one that drove the last integration step,
    // so applying it there would silently clamp the output against a transient
    // cursor that the spring never actually tracked).
    var forwardStep = false;
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
        final numSteps = (dtMicros / _maxSubStepMicros).ceil().clamp(
          1,
          1 << 20,
        );
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
        forwardStep = true;
      }
      // dtMicros == 0 → same-position re-evaluation. Don't integrate;
      // return the current focal so settings edits at a paused
      // playhead are reflected without phantom motion.
    }

    // Keep-in-view safety: the RETURNED focal is constrained so the live
    // cursor stays inside the framed viewport (minus an edge margin), for
    // every follow mode. This clamps the OUTPUT only — it deliberately does
    // NOT feed back into the spring's integration state. _smoothedFocal stays
    // unclamped (the transformer applies the reachable clamp at paint);
    // mutating it here would wind up spring velocity against an out-of-reach
    // (e.g. screen-corner) cursor and alter bounded/centered dynamics. Pure
    // function of (cursor, focal, zoom, framing), so live play, the
    // DeterministicFocalTrack replay, and export stay consistent. The
    // enter/exit ramps return earlier with their own framing, so this runs
    // only in the steady-state hold phase.
    //
    // Two guards:
    // 1. Only when the spring stepped FORWARD this frame. Backward-scrub and
    //    zero-dt re-evaluation frames deliver a cursor at a different timeline
    //    position than the spring tracked; applying the clamp there would
    //    silently remap the output against a transient cursor.
    // 2. Only when the cursor is in an UNREACHABLE zone (beyond the reachable
    //    focal bounds). For a reachable cursor the spring will naturally chase
    //    it; applying the clamp before the spring has closed the gap masks
    //    internal spring progress and defeats monotonicity assertions.
    Offset? focalOut;
    if (forwardStep && cursor != null) {
      final liveCursor = cursor;
      if ((fr.clampFocal(liveCursor, activeZoom.zoomLevel) - liveCursor)
              .distance >
          0.5) {
        focalOut = fr.clampFocalKeepCursorInView(
          _smoothedFocal!,
          liveCursor,
          activeZoom.zoomLevel,
          tuning.keepInViewEdgeMargin,
        );
      }
    }
    focalOut ??= _smoothedFocal!;
    return ZoomFocalUpdate(zoom: activeZoom, focal: focalOut);
  }

  /// Drop all smoothing state. Use when switching to a different
  /// recording, scrubbing past a zoom region, or in tests.
  void reset() {
    _smoothedFocal = null;
    _focalVx = 0;
    _focalVy = 0;
    _resetStrategies();
    _exitRampStartFocal = null;
    _exitRampStartReachable = null;
    _enterRampStartFocal = null;
    _enterRampTarget = null;
    _enterRampFocalTarget = null;
    _postEnterHoldTarget = null;
    _lastInBoundsCursor = null;
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
  static ({int exitStartUs, int exitUs})? _exitRampWindow(
      ZoomRegion zoom, double rampDurationScale) {
    final regionUs = zoom.duration.inMicroseconds;
    if (regionUs <= 0) return null;

    var enterUs = (zoom.enterDuration.inMicroseconds * rampDurationScale).round();
    var exitUs = (zoom.exitDuration.inMicroseconds * rampDurationScale).round();
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
  static ({int enterUs})? _enterRampWindow(
      ZoomRegion zoom, double rampDurationScale) {
    final regionUs = zoom.duration.inMicroseconds;
    if (regionUs <= 0) return null;
    var enterUs = (zoom.enterDuration.inMicroseconds * rampDurationScale).round();
    final exitUs = (zoom.exitDuration.inMicroseconds * rampDurationScale).round();
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

  static Offset _baseFocal(ZoomRegion zoom, Size videoSize) {
    if (!zoom.followCursor) return zoom.rect.center;
    return Offset(videoSize.width / 2, videoSize.height / 2);
  }

  /// Whether [cursor] falls within the video frame. Out-of-bounds samples
  /// come from multi-monitor recordings where the cursor is on another
  /// display; the follow camera freezes rather than chasing them.
  static bool _inBounds(Offset cursor, Size videoSize) {
    return cursor.dx >= 0 &&
        cursor.dy >= 0 &&
        cursor.dx <= videoSize.width &&
        cursor.dy <= videoSize.height;
  }

  static double _manualStyleBackload(ZoomRegion zoom) {
    final defaultBackload = manualBackloadForZoom(zoom.zoomLevel);
    if (zoom.followCursor) return defaultBackload;
    return zoom.manualPanBackload ?? defaultBackload;
  }

  // Closed-end lookup: includes `position == endTime` so the focal
  // controller still emits the exit-ramp completion frame (zoom factor
  // at 1.0×, focal at video centre). Delegates to [ZoomRegion.activeAt]
  // so all engine call sites share one definition of "active zoom at t".
  static ZoomRegion? _activeZoomAt(
    Duration position,
    List<ZoomRegion> zoomRegions,
  ) => ZoomRegion.activeAt(position, zoomRegions);
}

/// Result of a [ZoomFocalController.update] call when a zoom is active.
class ZoomFocalUpdate {
  const ZoomFocalUpdate({required this.zoom, required this.focal});
  final ZoomRegion zoom;
  final Offset focal;
}
