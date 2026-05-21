import 'dart:math' as math;

import 'package:flutter/animation.dart' show Offset;
import 'package:flutter/physics.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder/state/cursor_post_process.dart';

/// Stateful spring chase over the recorded cursor path.
///
/// Each call to [update] integrates a `SpringSimulation` per axis
/// forward by the playhead delta `dt = position − lastPosition`,
/// retargeted each frame to the recording's raw cursor position at the
/// new playhead **plus a partial velocity-feedforward term that
/// cancels half the spring's intrinsic phase lag**. Two simulations (X
/// and Y) run independently so diagonal motion follows the recorded
/// path rather than producing a Lissajous figure.
///
/// **Why partial feedforward.** A causal spring chasing a moving
/// target sits at `cursorAt(t − τ)`, where `τ = 2ζ/ωₙ` is its
/// analytical settle time (≈149 ms at the Smooth defaults, ≈67 ms at
/// Rapid). Targeting `raw + velocity × τ` cancels that lag *exactly*
/// — but it also makes every preset look the same during continuous
/// motion (Smooth, Medium, Rapid all sit on the raw path), erasing
/// the differences between presets the user picked. The compromise:
/// `raw + velocity × τ × [_feedforwardStrength]`, with the strength
/// at 0.5. That halves the steady-state lag (≈75 px at the Smooth
/// defaults vs. 149 px without compensation) while preserving the
/// preset's character — Smooth still feels softer than Rapid, just
/// not as draggy as a pure chase. Matches the half-shift the user
/// settled on for the FIR before springs.
///
/// Other invariants:
/// - **Scrub-aware.** A backward step or a jump >100 ms resets the
///   state to the raw position so scrubbing never strands a stale
///   velocity that would shoot the cursor across the screen on the
///   next forward play.
/// - **Click flag and cursor state come from `cursorAt(recording,
///   position)` at the rendered timestamp** — independent of the
///   spring's state, so a press/release fires at the recorded moment.
class CursorMotionController {
  // Spring state (one axis each). Initialised lazily on the first
  // call where a raw cursor sample is available.
  double _x = 0;
  double _y = 0;
  double _vx = 0;
  double _vy = 0;
  bool _primed = false;
  Duration? _lastPosition;

  // Result cache — same-position re-renders (parent setState double-
  // builders, repaint-on-resize, etc.) return without re-integrating.
  // Includes [cursorDelay] in the key so dragging the debug slider
  // while paused (position unchanged, delay changing) actually pushes
  // a fresh frame instead of serving the stale cached one.
  Duration? _cachedPosition;
  Duration? _cachedCursorDelay;
  CursorPostProcess? _cachedPostProcess;
  CursorMotionUpdate? _cachedResult;

  // Forward-step scrub-detection threshold is intentionally removed.
  //
  // The previous design treated any forward jump > 100 ms as a scrub
  // and re-primed the spring to the raw recorded position. That made
  // sense as a defensive measure for hot reloads / pause-resume, but
  // it also fired during ordinary frame stutters — a 120 ms paint
  // gap is unremarkable on a busy editor canvas and would teleport
  // the cursor sprite forward by `τ × velocity` (~75 px at Smooth,
  // 1000 px/s). The camera then sees the cursor jump and chases the
  // teleport, which the user perceives as a visible mid-flight
  // "jump" with no obvious trigger.
  //
  // [SpringSimulation] is a closed-form solver: integrating from
  // `(x, v)` forward by any `dt` lands the spring at a deterministic
  // `(x', v')` regardless of the size of `dt`. For our typical
  // critically-/over-damped presets the spring just settles toward
  // its target with no oscillation; even for an underdamped preset
  // the energy decays continuously rather than producing a fresh
  // ring. So a long-dt single integration is safe — and it preserves
  // the cursor sprite's "trail behind the camera" smoothness through
  // a stutter rather than introducing an artificial discontinuity.
  //
  // Backward scrubs are still reset (handled at the call site below)
  // because the spring's previous state was earned by forward
  // playback through different content.

  /// Back-look window for the scene-velocity finite difference.
  static const Duration _velocityLookback = Duration(milliseconds: 33);

  /// Fraction of the spring's analytical lag (τ) compensated by
  /// velocity feedforward. 1.0 = full cancellation (rendered cursor
  /// sits exactly on the recorded path, but presets all look the same
  /// during steady motion); 0.0 = no compensation (vanilla spring
  /// chase, ~149 px lag at Smooth defaults). 0.5 splits the difference:
  /// half the lag of a pure chase, and the preset's stiffness still
  /// changes the feel.
  ///
  /// This is the **peak** strength, applied only while the cursor is
  /// moving above [_feedforwardFullSpeedPxPerSec]. Below that the
  /// strength is faded toward zero so the target doesn't keep a lead
  /// of `raw + V × τ × 0.5` when V is decaying to zero — see the
  /// commentary on the smoothstep below for why this matters at clicks.
  static const double _feedforwardStrength = 0.5;

  /// Cursor speeds (px/s) at which the velocity feedforward is fully
  /// off vs. fully on. Between these speeds the strength is smooth-
  /// stepped — and outside, it's clamped.
  ///
  /// **Why fade.** With a constant strength, the feedforward target
  /// sits at `raw + velocity × τ × strength` and changes by
  /// `Δvelocity × τ × strength` between frames. When the cursor
  /// settles at a click site, velocity decays from V_high → 0 over
  /// the 33 ms [_velocityLookback] window — so over those 33 ms the
  /// target collapses inward by `V_high × τ × strength` pixels (≈ 75
  /// px at the Smooth preset, V=1000 px/s). The cursor sprite chases
  /// that collapse with its own lag, lands close to the raw click
  /// site, and the rendered camera focal — which tracks the sprite —
  /// **inherits the collapse, amplified by [ZoomRegion.zoomLevel]**.
  /// That's the "camera jumps on click" the user kept seeing: not a
  /// snap in the focal controller (we removed those), but the focal
  /// faithfully tracking a sprite trajectory whose target was
  /// collapsing inward. Fading feedforward to zero as the cursor
  /// decelerates means the target never has a meaningful lead when
  /// velocity is small, so there's nothing to collapse.
  ///
  /// The thresholds (200 / 800 px/s) are wider than the smooth-out
  /// (33 ms) window so even fast motions decay through the fade band
  /// over several frames — preventing the "fade" itself from being a
  /// discontinuity the user can see.
  static const double _feedforwardFadeStartPxPerSec = 200.0;
  static const double _feedforwardFullSpeedPxPerSec = 800.0;

  CursorMotionUpdate? update({
    required Duration position,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig config,
    required int fps,
    Duration cursorDelay = Duration.zero,
    CursorPostProcess postProcess = CursorPostProcess.none,
  }) {
    // Same-position re-render: serve the cached result without
    // stepping the spring forward (would compound noise from
    // repeated dt=0 evaluations). The cache key includes
    // [cursorDelay] so changes to the debug knob always punch through.
    if (_cachedPosition == position &&
        _cachedCursorDelay == cursorDelay &&
        _cachedPostProcess == postProcess &&
        _cachedResult != null) {
      return _cachedResult;
    }

    // Debug knob — shift the *query* position backward by
    // [cursorDelay]. Lets the user compensate for an app's UI redraw
    // lag so the cursor sprite visually arrives at UI elements at the
    // same moment those elements react. The spring's scrub-detection,
    // velocity, and click-state lookups all sample at the shifted
    // timestamp so the whole pipeline sees one consistent timeline.
    final queryPosition = cursorDelay == Duration.zero
        ? position
        : Duration(
            microseconds:
                position.inMicroseconds - cursorDelay.inMicroseconds);
    final raw = cursorAtFiltered(cursorRecording, queryPosition, postProcess);
    if (raw == null) {
      _cachedPosition = position;
      _cachedCursorDelay = cursorDelay;
      _cachedPostProcess = postProcess;
      _cachedResult =null;
      return null;
    }

    final spring = config.motionSpring;
    final velocity = _computeSceneVelocity(
      position: queryPosition,
      cursorRecording: cursorRecording,
      postProcess: postProcess,
    );

    // Snap mode (None preset / explicit snap spring): land on the
    // exact recorded sample closest to `position` — no interpolation.
    // The default `cursorAt` lookup linearly interpolates between the
    // two surrounding 60 Hz samples, which makes the cursor look soft
    // even when the spring is bypassed. Picking the nearest sample
    // instead means the rendered cursor sits on the recorded grid.
    // Keep the spring's persistent state in sync so a later preset
    // switch back to a real spring picks up from the right place.
    if (spring.isSnap) {
      // End-freeze still applies — clamp the snap query so the cursor
      // stops crawling toward the Stop button. Despike / state-debounce
      // are not applied in snap mode because the preset's whole point is
      // to land on the literal recorded grid sample.
      var snapQuery = queryPosition;
      if (postProcess.endFreezeMs > 0) {
        final last = cursorRecording.positions.last.timestampMicros;
        final cap = last - postProcess.endFreezeMs * 1000;
        if (snapQuery.inMicroseconds > cap) {
          snapQuery = Duration(microseconds: cap);
        }
      }
      final snapSample =
          cursorAtNearest(cursorRecording, snapQuery) ?? raw;
      _x = snapSample.x.toDouble();
      _y = snapSample.y.toDouble();
      _vx = 0;
      _vy = 0;
      _primed = true;
      _lastPosition = position;
      _cachedPosition = position;
      _cachedCursorDelay = cursorDelay;
      _cachedPostProcess = postProcess;
      _cachedResult =CursorMotionUpdate(
        screenPos: Offset(_x, _y),
        isClicked: snapSample.isClicked,
        velocityPxPerSec: velocity,
        state: snapSample.state,
      );
      return _cachedResult;
    }

    final lastPos = _lastPosition;
    final dtMicros = lastPos == null
        ? 0
        : position.inMicroseconds - lastPos.inMicroseconds;

    // Reset state on first call or on a backward step. After a
    // reset the rendered cursor IS the raw recorded position —
    // clicks land where the recording says they do regardless of
    // what state the spring was in before. Forward jumps (frame
    // stutter, long pause-resume) are NOT reset: the closed-form
    // SpringSimulation handles arbitrary-dt integration without
    // ringing for our presets, and resetting on stutter was the
    // mechanism producing the mid-flight "jumps" the user was
    // hitting — see the long comment on the removed
    // `_scrubThresholdForward` constant for the rationale.
    final shouldReset = !_primed || dtMicros < 0;
    if (shouldReset) {
      _x = raw.x.toDouble();
      _y = raw.y.toDouble();
      _vx = 0;
      _vy = 0;
      _primed = true;
      _lastPosition = position;
      _cachedPosition = position;
      _cachedCursorDelay = cursorDelay;
      _cachedPostProcess = postProcess;
      _cachedResult =CursorMotionUpdate(
        screenPos: Offset(_x, _y),
        isClicked: raw.isClicked,
        velocityPxPerSec: velocity,
        state: raw.state,
      );
      return _cachedResult;
    }

    if (dtMicros == 0) {
      // Playhead unchanged — no integration to do. Reuse cached state
      // (this branch shouldn't fire often because the same-position
      // cache above catches most of these; it's here for the case
      // where the result cache was invalidated for an unrelated
      // reason).
      _cachedPosition = position;
      _cachedCursorDelay = cursorDelay;
      _cachedPostProcess = postProcess;
      _cachedResult =CursorMotionUpdate(
        screenPos: Offset(_x, _y),
        isClicked: raw.isClicked,
        velocityPxPerSec: velocity,
        state: raw.state,
      );
      return _cachedResult;
    }

    final dt = dtMicros / 1e6;
    final desc = spring.toDescription();

    // Partial velocity feedforward — target a point ahead of the
    // recorded position by half the spring's analytical phase lag
    // (τ = 2ζ/ωₙ, multiplied by [_feedforwardStrength]). Halves the
    // steady-state lag a pure chase would produce, while preserving
    // each preset's distinctive feel.
    //
    // The strength is scaled by a smoothstep on cursor SPEED so the
    // feedforward fades to zero before the cursor actually stops —
    // see [_feedforwardFadeStartPxPerSec] for why. Above
    // [_feedforwardFullSpeedPxPerSec] the strength is full; below
    // [_feedforwardFadeStartPxPerSec] it's zero; in between it's a
    // smoothstep (C¹ continuous, so the derivative-of-target stays
    // bounded as speed crosses the band).
    final tauSec =
        2.0 * spring.damping * math.sqrt(spring.mass / spring.stiffness);
    final speed = velocity.distance;
    final fadeRange =
        _feedforwardFullSpeedPxPerSec - _feedforwardFadeStartPxPerSec;
    final fadeT = fadeRange <= 0
        ? 1.0
        : ((speed - _feedforwardFadeStartPxPerSec) / fadeRange)
            .clamp(0.0, 1.0);
    final fadeScale = fadeT * fadeT * (3.0 - 2.0 * fadeT);
    final leadSec = tauSec * _feedforwardStrength * fadeScale;
    final targetX = raw.x.toDouble() + velocity.dx * leadSec;
    final targetY = raw.y.toDouble() + velocity.dy * leadSec;

    // Integrate independently per axis so diagonal motion isn't
    // distorted by the spring's tendency to settle radially.
    final simX = SpringSimulation(desc, _x, targetX, _vx);
    _x = simX.x(dt);
    _vx = simX.dx(dt);
    final simY = SpringSimulation(desc, _y, targetY, _vy);
    _y = simY.x(dt);
    _vy = simY.dx(dt);

    _lastPosition = position;
    _cachedPosition = position;
    _cachedCursorDelay = cursorDelay;
    _cachedPostProcess = postProcess;
    _cachedResult = CursorMotionUpdate(
      screenPos: Offset(_x, _y),
      isClicked: raw.isClicked,
      velocityPxPerSec: velocity,
      state: raw.state,
    );
    return _cachedResult;
  }

  /// Drop persistent state so the next call re-primes from raw.
  /// Useful when the recording, fps, or any other anchoring input
  /// changes and the spring's previous (x, vx) values are no longer
  /// meaningful.
  void reset() {
    _primed = false;
    _x = 0;
    _y = 0;
    _vx = 0;
    _vy = 0;
    _lastPosition = null;
    _cachedPosition = null;
    _cachedCursorDelay = null;
    _cachedPostProcess = null;
    _cachedResult = null;
  }

  /// Scene velocity at video time [position]: the cursor's intrinsic
  /// motion at that timestamp in the recording, regardless of how the
  /// playhead got there. Stateless and direction-agnostic — forward
  /// play, backward scrub, and hover-jumps all return the same value
  /// at the same timestamp. Computed from RAW samples even though the
  /// rendered cursor follows the spring; that keeps the motion-blur
  /// trail anchored to where the cursor actually was, not where the
  /// spring is currently chasing.
  Offset _computeSceneVelocity({
    required Duration position,
    required CursorRecording cursorRecording,
    required CursorPostProcess postProcess,
  }) {
    if (position < _velocityLookback) return Offset.zero;
    final currentSample =
        cursorAtFiltered(cursorRecording, position, postProcess);
    if (currentSample == null) return Offset.zero;
    final prevSample = cursorAtFiltered(
      cursorRecording,
      position - _velocityLookback,
      postProcess,
    );
    if (prevSample == null) return Offset.zero;
    final dxPx = currentSample.x - prevSample.x;
    final dyPx = currentSample.y - prevSample.y;
    final invDt = 1e6 / _velocityLookback.inMicroseconds;
    return Offset(dxPx * invDt, dyPx * invDt);
  }
}

class CursorMotionUpdate {
  const CursorMotionUpdate({
    required this.screenPos,
    required this.isClicked,
    required this.velocityPxPerSec,
    this.state = CursorState.arrow,
  });
  final Offset screenPos;
  final bool isClicked;

  /// Smoothed cursor velocity in screen-space pixels per second.
  /// Zero on the first call, on backward scrubs, and whenever the
  /// previous-frame state isn't trustworthy.
  final Offset velocityPxPerSec;

  /// What the OS pointer looked like at the rendered timestamp. The
  /// painter uses this to pick the right glyph (I-beam over text,
  /// hand over a link, etc.).
  final CursorState state;
}
