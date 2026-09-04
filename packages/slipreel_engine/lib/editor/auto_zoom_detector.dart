import 'dart:math' as math;
import 'dart:ui';

import '../models/cursor_recording.dart';
import '../models/zoom_look.dart';
import '../models/zoom_region.dart';
import 'cursor_interaction.dart';
import 'interaction_classifier.dart';
import 'zoom_shape.dart';

/// Turns a `CursorRecording` into the editor's pre-populated zoom lane.
///
/// Pipeline: classify gestures ([InteractionClassifier]) → merge nearby
/// gestures into clusters → shape each group into a `ZoomRegion` via
/// [kZoomShapes] → merge adjacent regions.
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
  /// constructor so a solitary unclassified click keeps the historic
  /// envelope — 1.5×, 500ms lead-in, 1800ms hold, 500ms lead-out. The
  /// output is no longer byte-identical: `followCursor` flipped on for
  /// `click` on this branch, where the pre-classifier detector was
  /// anchored.
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

  /// [look] is the tilt + movement every emitted region is created with;
  /// callers pass the project's `defaultZoomLook`.
  List<ZoomRegion> detect({
    required CursorRecording cursor,
    required Size videoSize,
    required Duration videoDuration,
    ZoomLook look = ZoomLook.classic,
  }) {
    final interactions = classifier
        .classify(cursor, videoSize)
        .where((i) => _inBounds(i.anchor, videoSize))
        .toList();

    final regions = <ZoomRegion>[];
    for (final group in _cluster(interactions, videoSize)) {
      final region = _buildRegion(group, videoSize, videoDuration, look);
      if (region != null) regions.add(region);
    }
    return _mergeAdjacent(regions, videoSize);
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
    ZoomLook look,
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
      // `center` is the fitted union centre either way: load-bearing when
      // the region is anchored, unused (but still computed — harmless) when
      // it follows.
      var union = group.first.sweptBounds;
      var lowestMemberZoom = _shapeFor(group.first.kind).zoomLevel;
      var highestMemberZoom = lowestMemberZoom;
      var lastEnd = group.first.end;
      for (final it in group.skip(1)) {
        union = union.expandToInclude(it.sweptBounds);
        final z = _shapeFor(it.kind).zoomLevel;
        if (z < lowestMemberZoom) lowestMemberZoom = z;
        if (z > highestMemberZoom) highestMemberZoom = z;
        if (it.end > lastEnd) lastEnd = it.end;
      }
      final clippedUnion = _clipToVideo(union, videoSize);
      center = clippedUnion.center;
      enter = leadIn;
      exit = leadOut;
      follow = group.any((it) => _shapeFor(it.kind).followCursor);
      // Framing decisions that protect a union — "the widest member wins,
      // capped by what the union can fit" — apply only to ANCHORED regions:
      // an anchored region frames a static box that must contain every
      // member, so the widest member's requirement governs and the fit caps
      // it further. A following region has no union to frame — it tracks
      // the cursor — so there is nothing for that rule to protect, and it
      // takes the TIGHTEST member zoom instead. Using the widest-member rule
      // here would mean a single wide member (e.g. a drag) flattens every
      // other member's framing, including a deliberately tight one like
      // textEntry's, whenever the two end up in the same following region.
      regionZoom = follow
          ? highestMemberZoom
          : math.min(lowestMemberZoom, _fitZoom(clippedUnion, videoSize));
      // A merged cluster must never hold for less time than a lone click
      // would: the raw gesture span (e.g. two clicks 500ms apart) can be
      // far shorter than a single click's hold, which would make merging
      // worse than not merging at all. Together with the ZoomShape.maxHold
      // ceiling enforced in _cluster, a cluster's span is bounded on both
      // sides: [hold, ZoomShape.maxHold] = [1800ms, 6000ms] at defaults.
      final rawSpan = lastEnd - group.first.start;
      span = rawSpan < hold ? hold : rawSpan;
    }

    // A region that can only be framed at less than minClusterZoom is not a
    // zoom — it would render as a no-op lane entry, and because
    // _mergeAdjacent merges any region whose seam undercuts the ramps, it
    // would be merged into a genuine neighbour and widen it into a
    // following span covering both, which is worse than simply not
    // emitting it. No zoom is better than a fake one.
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
      tilt: look.tilt,
      movement: look.movement,
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

  /// Collapses regions whose seam is not worth rendering into one following
  /// region, so the camera pans across instead of ramping out to 1.0x and
  /// straight back in.
  ///
  /// Two consecutive regions merge when the gap between them is smaller
  /// than the ramps that crossing it would cost:
  ///
  ///     gap = next.startTime - (prev.startTime + prev.duration)
  ///     merge when gap < prev.exitDuration + next.enterDuration
  ///
  /// `gap` is NEGATIVE when the regions overlap, which is the common case —
  /// a 2.8 s region frequently starts before its predecessor ends — so every
  /// overlap merges. Above the threshold there is genuine room to return to
  /// full frame, and the regions are left alone.
  ///
  /// Merging replaces the previous truncate-the-earlier-region rule
  /// entirely; output is non-overlapping by construction because a merge
  /// consumes both inputs. The pass is greedy left to right, comparing the
  /// accumulated region (and therefore its last member's exit ramp) against
  /// the next one, so a run of three or more collapses into one span.
  ///
  /// A merged region always follows: merging exists so the camera can pan
  /// across the seam, and following is the mechanism that pans.
  List<ZoomRegion> _mergeAdjacent(List<ZoomRegion> regions, Size videoSize) {
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
      final prevEnd = prev.startTime + prev.duration;
      final gap = r.startTime - prevEnd;
      if (gap >= prev.exitDuration + r.enterDuration) {
        out.add(r);
        continue;
      }

      final rEnd = r.startTime + r.duration;
      // `r` can end before `prev` does when it is fully contained inside
      // the accumulated region (a short region starting and ending within
      // a long one). `end` and `exitDuration` must come from whichever
      // region actually ends later — the exit ramp belongs to the member
      // that finishes last, not to whichever member happens to be `r`.
      final prevEndsLater = prevEnd >= rEnd;
      final end = prevEndsLater ? prevEnd : rEnd;
      final exitDuration = prevEndsLater ? prev.exitDuration : r.exitDuration;
      // A merged region always follows (see the class doc above), so it has
      // no union to frame — it tracks the cursor. The "widest member wins"
      // rule only protects a static union, which makes it anchored-only;
      // here it would just mean one wide member flattens a tighter one
      // (e.g. textEntry's) for no reason a follow camera needs. Take the
      // TIGHTER of the two zooms instead.
      final zoom = prev.zoomLevel > r.zoomLevel ? prev.zoomLevel : r.zoomLevel;
      final union = prev.rect.expandToInclude(r.rect);
      out[out.length - 1] = prev.copyWith(
        duration: end - prev.startTime,
        exitDuration: exitDuration,
        zoomLevel: zoom,
        followCursor: true,
        // Unused while following, but it must stay valid and consistent
        // with `zoom` in case the flag is ever turned off.
        rect: _rectFor(union.center, zoom, videoSize),
      );
    }
    return out;
  }
}
