import 'dart:math' as math;
import 'dart:ui';

import '../models/cursor_recording.dart';
import '../models/tilt3d.dart';
import '../models/zoom_region.dart';
import 'cursor_interaction.dart';
import 'interaction_classifier.dart';
import 'zoom_shape.dart';

/// Turns a `CursorRecording` into the editor's pre-populated zoom lane.
///
/// Pipeline: classify gestures ([InteractionClassifier]) → merge nearby
/// gestures into clusters → shape each group into a `ZoomRegion` via
/// [kZoomShapes] → drop overlaps.
///
/// Replaces the pre-2026-08 click-only detector, whose isolation filter
/// dropped every click within 1.5 s of a neighbour and so emitted
/// *nothing* on click-dense recordings. See
/// `docs/superpowers/specs/2026-08-02-auto-zoom-interaction-classifier-design.md`.
class AutoZoomDetector {
  const AutoZoomDetector({
    this.zoomLevel = 1.5,
    this.leadIn = const Duration(milliseconds: 500),
    this.hold = const Duration(milliseconds: 1800),
    this.leadOut = const Duration(milliseconds: 500),
    this.clusterGap = const Duration(milliseconds: 1200),
    this.minClusterZoom = 1.25,
    this.classifier = const InteractionClassifier(),
  });

  /// Overrides for the `click` shape, preserved from the historic
  /// constructor so a solitary unclassified click is byte-identical to
  /// the pre-classifier detector's output.
  final double zoomLevel;
  final Duration leadIn;
  final Duration hold;
  final Duration leadOut;

  /// Maximum idle time between two gestures for them to join one
  /// cluster.
  final Duration clusterGap;

  /// A cluster may only absorb another gesture while the union of their
  /// swept bounds still fits at this magnification. Below it, the merged
  /// region would be so wide it isn't a zoom, so the cluster closes.
  final double minClusterZoom;

  final InteractionClassifier classifier;

  List<ZoomRegion> detect({
    required CursorRecording cursor,
    required Size videoSize,
    required Duration videoDuration,
  }) {
    final interactions = classifier
        .classify(cursor, videoSize)
        .where((i) => _inBounds(i.anchor, videoSize))
        .toList();

    final regions = <ZoomRegion>[];
    for (final group in _cluster(interactions, videoSize)) {
      final region = _buildRegion(group, videoSize, videoDuration);
      if (region != null) regions.add(region);
    }
    return _dropOverlaps(regions);
  }

  /// Skip gestures that happened off the captured display. On
  /// multi-monitor setups the cursor lives in global screen space, so a
  /// click on another monitor records as out-of-video-bounds (often
  /// negative). Zooming to a point clamped back in-bounds would land on
  /// a spot where nothing actually happened.
  bool _inBounds(Offset p, Size videoSize) =>
      p.dx >= 0 &&
      p.dy >= 0 &&
      p.dx <= videoSize.width &&
      p.dy <= videoSize.height;

  ZoomShape _shapeFor(InteractionKind kind) {
    if (kind == InteractionKind.click) {
      return ZoomShape(
        zoomLevel: zoomLevel,
        leadIn: leadIn,
        hold: hold,
        leadOut: leadOut,
        followCursor: false,
        holdTracksGesture: false,
        fitToSweptBounds: false,
      );
    }
    return kZoomShapes[kind]!;
  }

  List<List<CursorInteraction>> _cluster(
    List<CursorInteraction> items,
    Size videoSize,
  ) {
    if (items.isEmpty) return const [];
    final sorted = [...items]..sort((a, b) => a.start.compareTo(b.start));

    final groups = <List<CursorInteraction>>[];
    var current = <CursorInteraction>[sorted.first];
    var union = sorted.first.sweptBounds;
    var lastEnd = sorted.first.end;

    for (var i = 1; i < sorted.length; i++) {
      final next = sorted[i];
      final merged = union.expandToInclude(next.sweptBounds);
      final joins = (next.start - lastEnd) < clusterGap &&
          _fitZoom(merged, videoSize) >= minClusterZoom;

      if (joins) {
        current.add(next);
        union = merged;
        if (next.end > lastEnd) lastEnd = next.end;
      } else {
        groups.add(current);
        current = <CursorInteraction>[next];
        union = next.sweptBounds;
        lastEnd = next.end;
      }
    }
    groups.add(current);
    return groups;
  }

  /// Largest magnification at which [bounds] still fits the frame.
  /// A degenerate (zero-size) rect imposes no limit.
  double _fitZoom(Rect bounds, Size videoSize) {
    final fx = bounds.width > 0
        ? videoSize.width / bounds.width
        : double.infinity;
    final fy = bounds.height > 0
        ? videoSize.height / bounds.height
        : double.infinity;
    return math.min(fx, fy);
  }

  ZoomRegion? _buildRegion(
    List<CursorInteraction> group,
    Size videoSize,
    Duration videoDuration,
  ) {
    final double regionZoom;
    final Offset center;
    final Duration enter;
    final Duration exit;
    final Duration span;
    final bool follow;

    if (group.length == 1) {
      final it = group.single;
      final shape = _shapeFor(it.kind);
      enter = shape.leadIn;
      exit = shape.leadOut;
      span = shape.effectiveHold(it.gesture);
      follow = shape.followCursor;
      if (shape.fitToSweptBounds) {
        regionZoom =
            math.min(shape.zoomLevel, _fitZoom(it.sweptBounds, videoSize));
        center = it.sweptBounds.center;
      } else {
        regionZoom = shape.zoomLevel;
        center = it.anchor;
      }
    } else {
      // Merged cluster: anchored, framed over every member. Zoom takes
      // the LOWEST member preference rather than a "dominant kind" —
      // no tie-breaking rule needed, and it errs wide, which is the safe
      // direction when one region has to cover them all.
      var union = group.first.sweptBounds;
      var widest = _shapeFor(group.first.kind).zoomLevel;
      var lastEnd = group.first.end;
      for (final it in group.skip(1)) {
        union = union.expandToInclude(it.sweptBounds);
        final z = _shapeFor(it.kind).zoomLevel;
        if (z < widest) widest = z;
        if (it.end > lastEnd) lastEnd = it.end;
      }
      regionZoom = math.min(widest, _fitZoom(union, videoSize));
      center = union.center;
      enter = leadIn;
      exit = leadOut;
      span = lastEnd - group.first.start;
      follow = false;
    }

    final rawStart = group.first.start - enter;
    final start = rawStart.isNegative ? Duration.zero : rawStart;
    final total = enter + span + exit;
    final duration =
        (start + total) > videoDuration ? videoDuration - start : total;
    if (duration <= Duration.zero) return null;

    return ZoomRegion(
      rect: _rectFor(center, regionZoom, videoSize),
      startTime: start,
      duration: duration,
      zoomLevel: regionZoom,
      enterDuration: enter,
      exitDuration: exit,
      videoBounds: videoSize,
      followCursor: follow,
      tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
    );
  }

  Rect _rectFor(Offset center, double zoom, Size videoSize) {
    final safeZoom = zoom < 1.0 ? 1.0 : zoom;
    final w = videoSize.width / safeZoom;
    final h = videoSize.height / safeZoom;
    final cx = center.dx.clamp(w / 2, videoSize.width - w / 2);
    final cy = center.dy.clamp(h / 2, videoSize.height - h / 2);
    return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
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
