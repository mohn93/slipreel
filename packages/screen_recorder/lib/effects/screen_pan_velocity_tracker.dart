import 'package:flutter/material.dart';

/// Per-frame translation velocity of a `Matrix4` (the zoom transform
/// applied to the playback canvas / export composition).
///
/// Designed to be ticked once per frame: pass the current frame's
/// transform plus its [Duration] [position]. Returns the translation
/// velocity in canvas-px-per-second. Idempotent on duplicate
/// [position] (returns cached result without advancing state) — same
/// pattern as [ZoomFocalController]'s result cache. Backwards
/// [position] returns [Offset.zero].
class ScreenPanVelocityTracker {
  Offset? _lastTranslation;
  Duration? _lastPosition;
  Offset _lastResult = Offset.zero;

  /// Returns the translation velocity (px/sec) implied by going from
  /// the previous call's transform to [transform] over the wall-clock
  /// gap between [position] values. First call returns [Offset.zero].
  Offset update({
    required Matrix4 transform,
    required Duration position,
  }) {
    final tx = Offset(transform.entry(0, 3), transform.entry(1, 3));

    if (_lastPosition == null || _lastTranslation == null) {
      _lastTranslation = tx;
      _lastPosition = position;
      _lastResult = Offset.zero;
      return Offset.zero;
    }

    if (position == _lastPosition) {
      // Idempotent same-frame rebuild: don't advance state, return
      // last computed result.
      return _lastResult;
    }

    if (position < _lastPosition!) {
      // Scrub backwards: don't fabricate a negative-Δt velocity.
      // Re-anchor state to the new position so a subsequent forward
      // step is computed from here.
      _lastTranslation = tx;
      _lastPosition = position;
      _lastResult = Offset.zero;
      return Offset.zero;
    }

    final dtUs = (position - _lastPosition!).inMicroseconds;
    final dx = tx.dx - _lastTranslation!.dx;
    final dy = tx.dy - _lastTranslation!.dy;
    final inv = 1e6 / dtUs;
    final v = Offset(dx * inv, dy * inv);

    _lastTranslation = tx;
    _lastPosition = position;
    _lastResult = v;
    return v;
  }

  void reset() {
    _lastTranslation = null;
    _lastPosition = null;
    _lastResult = Offset.zero;
  }
}
