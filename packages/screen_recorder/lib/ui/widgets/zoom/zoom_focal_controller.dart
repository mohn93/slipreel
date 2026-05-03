import 'package:flutter/painting.dart' show Offset, Rect, Size;
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';

/// Stateful controller for the cursor-follow zoom focal point.
///
/// The renderer calls [update] once per frame with the current playhead
/// position and gets back either `null` (no zoom is active right now)
/// or the active zoom plus a smoothed focal point in video-pixel
/// coordinates.
///
/// Behavior:
///   - When no zoom is active at [position], internal smoothing state
///     is cleared so the next zoom snaps cleanly to its first frame.
///   - When a zoom becomes active (or a different zoom takes over), the
///     focal snaps to the target — no lerping from the previous zoom's
///     focal would just produce a sweep across the screen.
///   - While the same zoom remains active, the focal lerps toward the
///     target each call. The default factor (0.18) is what the
///     playback screen has shipped with.
///   - The target is the cursor sample at [position], or the zoom's
///     `rect.center` when [ZoomRegion.followCursor] is off / there's
///     no cursor data (legacy recording, window source, pre-warmup gap).
///   - When [ZoomRegion.boundedFollow] is on, the target is held at
///     the current focal as long as the cursor stays inside a centered
///     deadzone box of size `(videoSize / zoomLevel) * deadzoneRatio`.
///     When the cursor leaves the box, the target switches to the
///     cursor and the lerp draws the focal toward it; once the cursor
///     re-enters the moving deadzone, the focal locks again.
///
/// Pure-Dart, no Ticker / Stream / VideoPlayerController dependency,
/// so it can be unit-tested with synthetic inputs.
class ZoomFocalController {
  ZoomRegion? _previousActiveZoom;
  Offset? _smoothedFocal;

  /// Cached `(position → result)` for the most recent [update] call.
  /// Calling again with the same [position] returns the cached value
  /// without advancing smoothing — otherwise a parent setState that
  /// triggers an extra builder run for the same frame would lerp the
  /// focal twice and visibly jump the zoom Transform's translate.
  Duration? _cachedPosition;
  ZoomFocalUpdate? _cachedResult;

  /// Last smoothed focal returned. Exposed for the debug HUD that
  /// renders the focal as a hollow yellow ring.
  Offset? get smoothedFocal => _smoothedFocal;

  /// Compute the smoothed focal for the current frame.
  ///
  /// Returns `null` when no zoom region is active at [position].
  /// Idempotent for the same [position] — see [_cachedPosition].
  ///
  /// [videoSize] is the source video resolution in pixels and is used
  /// to size the deadzone box for bounded-follow zooms (the visible
  /// viewport in source pixels is `videoSize / zoom.zoomLevel`).
  ZoomFocalUpdate? update({
    required Duration position,
    required List<ZoomRegion> zoomRegions,
    required CursorRecording cursorRecording,
    required Size videoSize,
    double smoothing = 0.18,
  }) {
    if (_cachedPosition == position) {
      return _cachedResult;
    }
    _cachedPosition = position;

    final activeZoom = _activeZoomAt(position, zoomRegions);
    if (activeZoom == null) {
      _previousActiveZoom = null;
      _smoothedFocal = null;
      _cachedResult = null;
      return null;
    }

    final cursor = cursorAt(cursorRecording, position);
    final cursorOffset =
        cursor == null ? null : Offset(cursor.x, cursor.y);

    // The "ideal" target — where the camera would teleport to if there
    // were no smoothing or deadzone.
    final Offset baseTarget;
    if (!activeZoom.followCursor || cursorOffset == null) {
      baseTarget = activeZoom.rect.center;
    } else {
      baseTarget = cursorOffset;
    }

    // First frame of this zoom — snap, never lerp.
    if (!identical(activeZoom, _previousActiveZoom)) {
      _previousActiveZoom = activeZoom;
      _smoothedFocal = baseTarget;
      _cachedResult =
          ZoomFocalUpdate(zoom: activeZoom, focal: baseTarget);
      return _cachedResult;
    }

    // Apply the deadzone (only when actually following the cursor).
    // Effective target = current focal while cursor is inside a box
    // of size (viewport * deadzoneRatio) centered on the focal;
    // otherwise the target follows the cursor and the lerp drags the
    // focal toward it.
    Offset target = baseTarget;
    if (activeZoom.followCursor &&
        activeZoom.boundedFollow &&
        cursorOffset != null &&
        _smoothedFocal != null &&
        activeZoom.deadzoneRatio > 0.0 &&
        videoSize.width > 0 &&
        videoSize.height > 0) {
      final z = activeZoom.zoomLevel;
      final dzW = (videoSize.width / z) * activeZoom.deadzoneRatio;
      final dzH = (videoSize.height / z) * activeZoom.deadzoneRatio;
      final dz = Rect.fromCenter(
        center: _smoothedFocal!,
        width: dzW,
        height: dzH,
      );
      if (dz.contains(cursorOffset)) {
        target = _smoothedFocal!;
      }
    }

    final prev = _smoothedFocal;
    _smoothedFocal =
        prev == null ? target : Offset.lerp(prev, target, smoothing)!;

    _cachedResult =
        ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
    return _cachedResult;
  }

  /// Drop all smoothing state. Use when switching to a different
  /// recording, scrubbing past a zoom region, or in tests.
  void reset() {
    _previousActiveZoom = null;
    _smoothedFocal = null;
    _cachedPosition = null;
    _cachedResult = null;
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
