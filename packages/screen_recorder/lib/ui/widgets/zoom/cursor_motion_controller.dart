import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';

/// Stateless FIR convolution over the recorded cursor path.
///
/// Each `update` builds (or reuses) a kernel from the active config's
/// `(window, curve)` pair, then samples the recorded cursor at past
/// times relative to `position` weighted by the kernel. There's no
/// running smoothed-state — every frame is computed from scratch —
/// so scrubbing the playhead can never strand a stale value.
///
/// Two caches:
///   - kernel cache, keyed by (window, curve) — invalidated when the
///     config changes,
///   - result cache, keyed by `position` — fixes the parent-setState
///     double-builder problem (same as ZoomFocalController).
class CursorMotionController {
  // Kernel cache.
  Duration? _kernelWindow;
  Curve? _kernelCurve;
  int? _kernelFps;
  List<double>? _kernelWeights;

  // Result cache (idempotency for same-frame rebuilds).
  Duration? _cachedPosition;
  CursorMotionUpdate? _cachedResult;
  Object? _cachedConfigKey;

  // Velocity tracking. Carries last *advanced* state so duplicate-
  // position calls don't fake a Δt=0 step.
  Duration? _velPrevPosition;
  Offset? _velPrevScreenPos;

  CursorMotionUpdate? update({
    required Duration position,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig config,
    required int fps,
  }) {
    final configKey = _configKey(config, fps);
    if (_cachedPosition == position && _cachedConfigKey == configKey) {
      return _cachedResult;
    }
    _cachedPosition = position;
    _cachedConfigKey = configKey;

    if (config.window == Duration.zero) {
      // Snap path — no FIR, no kernel.
      final raw = cursorAt(cursorRecording, position);
      if (raw == null) {
        _cachedResult = null;
        return null;
      }
      final screenPos = Offset(raw.x, raw.y);
      final velocity = _computeVelocity(screenPos: screenPos, position: position);
      _cachedResult = CursorMotionUpdate(
        screenPos: screenPos,
        isClicked: raw.isClicked,
        velocityPxPerSec: velocity,
      );
      return _cachedResult;
    }

    final weights = _ensureKernel(window: config.window, curve: config.firCurve, fps: fps);
    final framePeriodMicros = (1000000 / fps).round();

    bool clicked = false;
    double accX = 0;
    double accY = 0;
    double accW = 0;
    for (var i = 0; i < weights.length; i++) {
      final tapMicros = position.inMicroseconds - i * framePeriodMicros;
      final tapTime = Duration(
        microseconds: tapMicros < 0 ? 0 : tapMicros,
      );
      final s = cursorAt(cursorRecording, tapTime);
      if (s == null) continue;
      accX += s.x * weights[i];
      accY += s.y * weights[i];
      accW += weights[i];
      // Render the most-recent tap's click state — matches the legacy
      // IIR behavior. Older taps don't extend the click visibly.
      if (i == 0) clicked = s.isClicked;
    }
    if (accW == 0) {
      _cachedResult = null;
      return null;
    }
    final inv = 1.0 / accW;
    final screenPos = Offset(accX * inv, accY * inv);
    final velocity = _computeVelocity(screenPos: screenPos, position: position);
    _cachedResult = CursorMotionUpdate(
      screenPos: screenPos,
      isClicked: clicked,
      velocityPxPerSec: velocity,
    );
    return _cachedResult;
  }

  void reset() {
    _cachedPosition = null;
    _cachedResult = null;
    _cachedConfigKey = null;
    _velPrevPosition = null;
    _velPrevScreenPos = null;
  }

  // --- internals --------------------------------------------------------

  Object _configKey(CursorAnimationConfig c, int fps) =>
      Object.hash(c.window.inMicroseconds, c.firCurve.runtimeType,
          identityHashCode(c.firCurve), fps);

  List<double> _ensureKernel({
    required Duration window,
    required Curve curve,
    required int fps,
  }) {
    if (_kernelWindow == window &&
        identical(_kernelCurve, curve) &&
        _kernelFps == fps &&
        _kernelWeights != null) {
      return _kernelWeights!;
    }

    final n = math.max(1, (window.inMicroseconds * fps / 1000000).round());
    final weights = List<double>.filled(n, 0);
    double sum = 0;
    for (var i = 0; i < n; i++) {
      // i indexes taps from "now" (i=0) backward in time. The kernel
      // must put the curve's *initial* derivative on the most recent
      // tap so an ease-out curve produces ease-out cursor motion: a
      // step input then settles as `curve(T/W)` (fast start, slow
      // settle). Mapping i=0 → curve(1/n) - curve(0).
      final hi = curve.transform(((i + 1) / n).clamp(0.0, 1.0));
      final lo = curve.transform((i / n).clamp(0.0, 1.0));
      // Kernel must be non-negative — an FIR that averages past samples
      // can't have "anti-weight" frames. For overshoot curves where the
      // signed derivative dips negative, treat that segment as zero
      // contribution rather than mirroring it.
      final w = math.max(0.0, hi - lo);
      weights[i] = w;
      sum += w;
    }
    if (sum > 0) {
      for (var i = 0; i < n; i++) {
        weights[i] /= sum;
      }
    } else {
      // Degenerate curve — fall back to "snap to most recent tap".
      weights[0] = 1.0;
    }

    _kernelWindow = window;
    _kernelCurve = curve;
    _kernelFps = fps;
    _kernelWeights = weights;
    return weights;
  }

  Offset _computeVelocity({
    required Offset screenPos,
    required Duration position,
  }) {
    final prevPos = _velPrevPosition;
    final prevScreen = _velPrevScreenPos;
    if (prevPos == null || prevScreen == null) {
      _velPrevPosition = position;
      _velPrevScreenPos = screenPos;
      return Offset.zero;
    }
    if (position < prevPos) {
      // Scrub backwards: re-anchor and report zero.
      _velPrevPosition = position;
      _velPrevScreenPos = screenPos;
      return Offset.zero;
    }
    if (position == prevPos) {
      // Same-frame rebuild — should be served from _cachedResult
      // already, but guard the no-Δt case anyway.
      return Offset.zero;
    }
    final dtUs = (position - prevPos).inMicroseconds;
    final dx = screenPos.dx - prevScreen.dx;
    final dy = screenPos.dy - prevScreen.dy;
    final inv = 1e6 / dtUs;
    _velPrevPosition = position;
    _velPrevScreenPos = screenPos;
    return Offset(dx * inv, dy * inv);
  }
}

class CursorMotionUpdate {
  const CursorMotionUpdate({
    required this.screenPos,
    required this.isClicked,
    required this.velocityPxPerSec,
  });
  final Offset screenPos;
  final bool isClicked;

  /// Smoothed cursor velocity in screen-space pixels per second.
  /// Zero on the first call, on backward scrubs, and whenever the
  /// previous-frame state isn't trustworthy.
  final Offset velocityPxPerSec;
}
