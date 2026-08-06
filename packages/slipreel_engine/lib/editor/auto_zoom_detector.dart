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
/// [kZoomShapes] → resolve overlaps.
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
  ///
  /// [zoomLevel] must stay at or above [minClusterZoom]: the emission
  /// floor in [_buildRegion] rejects anything shallower, so setting it
  /// below would silently produce zero regions for every plain click.
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
  ///
  /// It is also the *universal emission floor*: the guard at the end of
  /// [_buildRegion] returns null for any region — clustered or solitary —
  /// that can only be framed below this magnification, so nothing
  /// shallower than this is ever emitted at all.
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
    return _resolveOverlaps(regions);
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
        followCursor: true,
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
      // Third gate: a cluster's span is capped, so an anchored click-a-second
      // demo inside one app window splits into a run of regions rather than
      // merging into a single minutes-long zoom. minClusterZoom of 1.25
      // tolerates a union covering ~80% of the frame, so the spatial gate
      // alone will not stop that. Like the other two gates, breaching it
      // closes the cluster and starts a new one at `next` — the span is
      // never truncated mid-gesture.
      //
      // The ceiling is a property of ANCHORED clusters only, though: it
      // exists because a wide anchored union is a crop of the whole video
      // rather than a zoom. A following cluster has no union to frame — it
      // tracks the cursor — so a long one is a sustained tracking shot,
      // which is the intended result of merging, and the ceiling does not
      // apply to it.
      final prospectiveMembers = <CursorInteraction>[...current, next];
      final wouldFollow = prospectiveMembers
          .any((m) => _shapeFor(m.kind).followCursor);
      final prospectiveSpan = next.end - current.first.start;
      final joins = (next.start - lastEnd) < clusterGap &&
          _fitZoom(merged, videoSize) >= minClusterZoom &&
          (wouldFollow || prospectiveSpan <= ZoomShape.maxHold);

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

  /// Swept bounds can extend past the captured display on multi-monitor
  /// setups — only the press anchor is bounds-checked. Clip before fitting
  /// so an off-display sweep cannot drive the fit below 1.0.
  Rect _clipToVideo(Rect r, Size videoSize) =>
      r.intersect(Rect.fromLTWH(0, 0, videoSize.width, videoSize.height));

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
        final clippedBounds = _clipToVideo(it.sweptBounds, videoSize);
        regionZoom =
            math.min(shape.zoomLevel, _fitZoom(clippedBounds, videoSize));
        center = clippedBounds.center;
      } else {
        regionZoom = shape.zoomLevel;
        center = it.anchor;
      }
    } else {
      // Merged cluster: framed over every member when it does not follow
      // (see `follow` below). Zoom takes the LOWEST member preference
      // rather than a "dominant kind" — no tie-breaking rule needed, and
      // it errs wide, which is the safe direction when one region has to
      // cover them all.
      var union = group.first.sweptBounds;
      var widest = _shapeFor(group.first.kind).zoomLevel;
      var lastEnd = group.first.end;
      for (final it in group.skip(1)) {
        union = union.expandToInclude(it.sweptBounds);
        final z = _shapeFor(it.kind).zoomLevel;
        if (z < widest) widest = z;
        if (it.end > lastEnd) lastEnd = it.end;
      }
      final clippedUnion = _clipToVideo(union, videoSize);
      regionZoom = math.min(widest, _fitZoom(clippedUnion, videoSize));
      center = clippedUnion.center;
      enter = leadIn;
      exit = leadOut;
      // A merged cluster must never hold for less time than a lone click
      // would: the raw gesture span (e.g. two clicks 500ms apart) can be
      // far shorter than a single click's hold, which would make merging
      // worse than not merging at all. Together with the ZoomShape.maxHold
      // ceiling enforced in _cluster, a cluster's span is bounded on both
      // sides: [hold, ZoomShape.maxHold] = [1800ms, 6000ms] at defaults.
      final rawSpan = lastEnd - group.first.start;
      span = rawSpan < hold ? hold : rawSpan;
      follow = group.any((it) => _shapeFor(it.kind).followCursor);
    }

    // A region that can only be framed at less than minClusterZoom is not a
    // zoom — it would render as a no-op lane entry, and because
    // _resolveOverlaps is greedy it could truncate — or, if the trim would
    // not fit both ramps, shadow entirely — a genuine zoom starting inside
    // its window. No zoom is better than a fake one.
    if (regionZoom < minClusterZoom) return null;

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

  /// Removes overlap between regions by TRUNCATING the earlier one to end
  /// exactly where the next begins, so both interactions stay represented.
  ///
  /// This branch made regions substantially longer — a drag can run 6.95 s
  /// and a cluster longer still — so the historic "keep the first, discard
  /// the later" rule now silently suppresses far more than it used to.
  ///
  /// Truncation only applies while the shortened region can still render
  /// as a zoom: its remaining duration must fit both ramps
  /// (`enterDuration + exitDuration`). When it cannot, we fall back to the
  /// historic rule — the earlier region keeps its full length and the
  /// later one is discarded.
  List<ZoomRegion> _resolveOverlaps(List<ZoomRegion> regions) {
    if (regions.isEmpty) return const [];
    final sorted = [...regions]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final out = <ZoomRegion>[];
    for (final r in sorted) {
      if (out.isEmpty) {
        out.add(r);
        continue;
      }
      final prev = out.last;
      if (r.startTime >= prev.startTime + prev.duration) {
        out.add(r);
        continue;
      }
      final trimmed = r.startTime - prev.startTime;
      // This guard compares against unscaled ramp durations. The renderer
      // multiplies both enterDuration and exitDuration by rampDurationScale
      // (e.g., 1.7 for the "Smooth" animation preset), so a region truncated
      // to between 1000ms and 1700ms at this stage will have its ramps
      // proportionally compressed during playback and may not reach full zoom.
      // The detector cannot know the project's animation preset at detect()
      // time (it only receives cursor, videoSize, and videoDuration), so this
      // shallow-truncation limitation is inherent and not addressable here.
      if (trimmed >= prev.enterDuration + prev.exitDuration) {
        out[out.length - 1] = prev.copyWith(duration: trimmed);
        out.add(r);
      }
      // Otherwise `prev` survives at full length and `r` is dropped: a
      // region shorter than its own ramps has no hold left to read as a
      // zoom, so half a region each is worse than one whole one.
    }
    return out;
  }
}
