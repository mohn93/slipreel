import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Time-aware exponential moving average filter for the cursor's
/// combined viewport velocity (cursor scene motion + camera pan).
///
/// Raw frame-to-frame velocity has two failure modes that show up in
/// the motion-blur trail:
///   1. Magnitude jitter — small noise around an activation threshold
///      makes the blur turn on/off frame-to-frame (visible flicker).
///   2. Direction jitter — when the velocity magnitude is small, the
///      unit vector is dominated by noise, so the trail orientation
///      flaps around even when the cursor is moving roughly straight.
///
/// EMA with a time constant of [_tauSec] dampens both: a τ around
/// 100 ms attenuates frame-rate-band noise while still tracking real
/// velocity changes within ~3 frames.
///
/// The filter is time-aware: it uses the [Duration] gap between calls
/// to compute alpha, so the smoothing behaves consistently regardless
/// of the calling rate (60 Hz preview vs export at output FPS).
class EmaVelocityFilter {
  static const double _tauSec = 0.10;

  /// Gaps larger than this re-seed instead of integrating — a long
  /// gap means the previous sample is too stale to blend against
  /// (frame skip, scrub, tab backgrounding, etc).
  static const Duration _maxGap = Duration(milliseconds: 500);

  Offset? _smoothed;
  Duration? _lastPosition;

  /// Returns the smoothed velocity for [raw] at [position]. Re-seeds
  /// to [raw] on the first call, on backward [position], and across
  /// gaps larger than [_maxGap].
  Offset filter(Offset raw, Duration position) {
    final last = _lastPosition;
    if (last == null || position <= last || position - last > _maxGap) {
      _smoothed = raw;
      _lastPosition = position;
      return raw;
    }
    final dtSec = (position - last).inMicroseconds / 1e6;
    final alpha = 1.0 - math.exp(-dtSec / _tauSec);
    final prev = _smoothed!;
    final next = Offset(
      prev.dx + (raw.dx - prev.dx) * alpha,
      prev.dy + (raw.dy - prev.dy) * alpha,
    );
    _smoothed = next;
    _lastPosition = position;
    return next;
  }

  void reset() {
    _smoothed = null;
    _lastPosition = null;
  }
}
