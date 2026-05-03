import 'package:flutter/painting.dart' show Offset;
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';

/// Stateful controller for the synthetic cursor's on-screen position.
///
/// The renderer calls [update] once per frame with the current playhead
/// position and gets back either `null` (no recorded cursor sample at
/// this time) or a smoothed [Offset] in screen-space pixels.
///
/// Lerps the rendered position toward the recorded position by
/// [smoothing] each frame:
///   - 1.0 → no smoothing, cursor draws exactly at the recorded
///     position (matches the historical behavior).
///   - lower → cursor visibly lags then catches up gracefully.
///
/// Idempotent for the same [position] so a parent setState that
/// triggers an extra builder run for the same frame doesn't lerp
/// twice and visibly jump the cursor.
class CursorMotionController {
  /// Beyond this gap between consecutive [update] calls we treat the
  /// playhead as scrubbed (or jumped) and snap to the new raw position
  /// instead of lerping — otherwise the cursor would visibly drift
  /// across the screen at the smoothing rate.
  static const Duration _snapThreshold = Duration(milliseconds: 100);

  Offset? _smoothed;
  Duration? _lastSmoothedAt;
  Duration? _cachedPosition;
  CursorMotionUpdate? _cachedResult;

  CursorMotionUpdate? update({
    required Duration position,
    required CursorRecording cursorRecording,
    double smoothing = 1.0,
  }) {
    if (_cachedPosition == position) return _cachedResult;
    _cachedPosition = position;

    final raw = cursorAt(cursorRecording, position);
    if (raw == null) {
      _smoothed = null;
      _lastSmoothedAt = null;
      _cachedResult = null;
      return null;
    }

    final rawOffset = Offset(raw.x, raw.y);
    final scrubbed = _lastSmoothedAt == null ||
        (position - _lastSmoothedAt!).abs() > _snapThreshold;
    if (_smoothed == null || smoothing >= 1.0 || scrubbed) {
      _smoothed = rawOffset;
    } else {
      _smoothed = Offset.lerp(_smoothed!, rawOffset, smoothing)!;
    }
    _lastSmoothedAt = position;

    _cachedResult = CursorMotionUpdate(
      screenPos: _smoothed!,
      isClicked: raw.isClicked,
    );
    return _cachedResult;
  }

  /// Drop all smoothing state. Use when switching recordings or
  /// scrubbing past gaps so the next call snaps cleanly.
  void reset() {
    _smoothed = null;
    _lastSmoothedAt = null;
    _cachedPosition = null;
    _cachedResult = null;
  }
}

class CursorMotionUpdate {
  const CursorMotionUpdate({
    required this.screenPos,
    required this.isClicked,
  });
  final Offset screenPos;
  final bool isClicked;
}
