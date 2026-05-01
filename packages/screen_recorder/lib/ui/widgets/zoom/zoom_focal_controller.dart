import 'package:flutter/painting.dart' show Offset;
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
///     `rect.center` if no cursor data is available (legacy recording,
///     window source, or pre-warmup gap).
///
/// Pure-Dart, no Ticker / Stream / VideoPlayerController dependency,
/// so it can be unit-tested with synthetic inputs.
class ZoomFocalController {
  ZoomRegion? _previousActiveZoom;
  Offset? _smoothedFocal;

  /// Last smoothed focal returned. Exposed for the debug HUD that
  /// renders the focal as a hollow yellow ring.
  Offset? get smoothedFocal => _smoothedFocal;

  /// Compute the smoothed focal for the current frame.
  ///
  /// Returns `null` when no zoom region is active at [position].
  ZoomFocalUpdate? update({
    required Duration position,
    required List<ZoomRegion> zoomRegions,
    required CursorRecording cursorRecording,
    double smoothing = 0.18,
  }) {
    final activeZoom = _activeZoomAt(position, zoomRegions);
    if (activeZoom == null) {
      _previousActiveZoom = null;
      _smoothedFocal = null;
      return null;
    }

    final rawFocal = _rawFocalFor(
      activeZoom: activeZoom,
      position: position,
      cursorRecording: cursorRecording,
    );

    if (!identical(activeZoom, _previousActiveZoom)) {
      _previousActiveZoom = activeZoom;
      _smoothedFocal = rawFocal;
    } else {
      final prev = _smoothedFocal;
      _smoothedFocal =
          prev == null ? rawFocal : Offset.lerp(prev, rawFocal, smoothing)!;
    }

    return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
  }

  /// Drop all smoothing state. Use when switching to a different
  /// recording, scrubbing past a zoom region, or in tests.
  void reset() {
    _previousActiveZoom = null;
    _smoothedFocal = null;
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

  static Offset _rawFocalFor({
    required ZoomRegion activeZoom,
    required Duration position,
    required CursorRecording cursorRecording,
  }) {
    final cursor = cursorAt(cursorRecording, position);
    if (cursor != null) return Offset(cursor.x, cursor.y);
    return activeZoom.rect.center;
  }
}

/// Result of a [ZoomFocalController.update] call when a zoom is active.
class ZoomFocalUpdate {
  const ZoomFocalUpdate({required this.zoom, required this.focal});
  final ZoomRegion zoom;
  final Offset focal;
}
