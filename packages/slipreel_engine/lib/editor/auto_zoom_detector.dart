import 'dart:ui';

import '../models/cursor_recording.dart';
import '../models/zoom_region.dart';

/// Pure-function click→zoom detector. Walks a `CursorRecording`, finds
/// rising edges of `isClicked`, keeps only clicks that are at least
/// `isolationWindow` away from their neighbours, and emits one `ZoomRegion`
/// per surviving click — centred on the click position, sized for `zoomLevel`,
/// clamped to the video bounds, never extending past the recording's edges.
///
/// Defaults: 1.5× zoom, 1.5 s isolation window, 400 ms lead-in + 1.8 s hold
/// + 300 ms lead-out = 2.5 s total duration. `followCursor: false` — the zoom
/// stays anchored at the click; user can flip it on in the inspector.
class AutoZoomDetector {
  const AutoZoomDetector({
    this.zoomLevel = 1.5,
    this.isolationWindow = const Duration(milliseconds: 1500),
    this.leadIn = const Duration(milliseconds: 400),
    this.hold = const Duration(milliseconds: 1800),
    this.leadOut = const Duration(milliseconds: 300),
  });

  final double zoomLevel;
  final Duration isolationWindow;
  final Duration leadIn;
  final Duration hold;
  final Duration leadOut;

  Duration get _totalDuration => leadIn + hold + leadOut;

  List<ZoomRegion> detect({
    required CursorRecording cursor,
    required Size videoSize,
    required Duration videoDuration,
  }) {
    final clicks = _findClickRisingEdges(cursor);
    final isolated = _filterIsolated(clicks);
    final regions = <ZoomRegion>[];
    for (final click in isolated) {
      final region = _buildRegion(click, videoSize, videoDuration);
      if (region != null) regions.add(region);
    }
    return _dropOverlaps(regions);
  }

  List<_Click> _findClickRisingEdges(CursorRecording cursor) {
    final out = <_Click>[];
    var prev = false;
    for (final pos in cursor.positions) {
      if (pos.isClicked && !prev) {
        out.add(_Click(
          t: Duration(microseconds: pos.timestampMicros),
          x: pos.x,
          y: pos.y,
        ));
      }
      prev = pos.isClicked;
    }
    return out;
  }

  List<_Click> _filterIsolated(List<_Click> clicks) {
    if (clicks.isEmpty) return const [];
    final out = <_Click>[];
    // First/last clicks compare against an effectively-infinite gap on the
    // missing side so a deliberate single click at the start or end still
    // counts as isolated.
    const infinite = Duration(days: 1);
    for (var i = 0; i < clicks.length; i++) {
      final c = clicks[i];
      final prevGap = i == 0 ? infinite : c.t - clicks[i - 1].t;
      final nextGap =
          i == clicks.length - 1 ? infinite : clicks[i + 1].t - c.t;
      if (prevGap >= isolationWindow && nextGap >= isolationWindow) {
        out.add(c);
      }
    }
    return out;
  }

  ZoomRegion? _buildRegion(
      _Click click, Size videoSize, Duration videoDuration) {
    final raw = click.t - leadIn;
    final start = raw.isNegative ? Duration.zero : raw;
    final endCandidate = start + _totalDuration;
    final duration = endCandidate > videoDuration
        ? videoDuration - start
        : _totalDuration;
    if (duration <= Duration.zero) return null;

    final w = videoSize.width / zoomLevel;
    final h = videoSize.height / zoomLevel;
    final cx = click.x.clamp(w / 2, videoSize.width - w / 2);
    final cy = click.y.clamp(h / 2, videoSize.height - h / 2);
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);

    return ZoomRegion(
      rect: rect,
      startTime: start,
      duration: duration,
      zoomLevel: zoomLevel,
      enterDuration: leadIn,
      exitDuration: leadOut,
      videoBounds: videoSize,
      followCursor: false,
    );
  }

  List<ZoomRegion> _dropOverlaps(List<ZoomRegion> regions) {
    if (regions.isEmpty) return const [];
    final sorted = [...regions]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final out = <ZoomRegion>[];
    for (final r in sorted) {
      if (out.isEmpty ||
          r.startTime >= out.last.startTime + out.last.duration) {
        out.add(r);
      }
    }
    return out;
  }
}

class _Click {
  const _Click({required this.t, required this.x, required this.y});
  final Duration t;
  final double x;
  final double y;
}
