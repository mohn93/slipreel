import 'package:flutter/material.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/seam_metrics.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart'
    show TrimDragInfo, TrimSide;

/// Horizontal overlay strip that renders one [CutMarker] per seam
/// between adjacent slices, plus two edge markers: one at the very
/// start (for the first slice's outer start-trim) and one at the very
/// end (for the last slice's outer end-trim). Edge markers only
/// appear when their corresponding outer trim is non-zero — there's
/// no merge target at the edges, so a zero-trim edge marker has
/// nothing to do.
///
/// Sits ABOVE the clip lane, allocating its own [CutMarker.kHitHeight]
/// of vertical space so the markers are inside its render box (and
/// therefore hit-testable). The strip is itself sized to
/// [CutMarker.kHitHeight] tall — its parent decides where it sits
/// relative to the clip lane.
class CutMarkerStrip extends StatelessWidget {
  const CutMarkerStrip({
    super.key,
    required this.clips,
    required this.pixelsPerSecond,
    required this.onClearSeamTrims,
    required this.onMergeSeam,
    required this.onClearStartTrim,
    required this.onClearEndTrim,
    this.dragging = false,
    this.activeDrag,
  });

  final List<ClipSlice> clips;
  final double pixelsPerSecond;
  final ValueChanged<int> onClearSeamTrims;
  final ValueChanged<int> onMergeSeam;
  /// Tap on the LEFT edge marker — restore the first slice's outer
  /// start-trim back to its cut bound. Only fires when the marker is
  /// visible (i.e. that trim is > 0).
  final VoidCallback onClearStartTrim;
  /// Tap on the RIGHT edge marker — restore the last slice's outer
  /// end-trim back to its cut bound. Only fires when the marker is
  /// visible (i.e. that trim is > 0).
  final VoidCallback onClearEndTrim;
  final bool dragging;
  /// Which (slice, side) is currently being trimmed. The marker that
  /// corresponds to this edge stays at full opacity while the others
  /// fade — the user is acting on it, so it shouldn't fade away with
  /// the rest. null when no trim drag is in flight.
  final TrimDragInfo? activeDrag;

  @override
  Widget build(BuildContext context) {
    if (clips.isEmpty) {
      return const SizedBox(height: CutMarker.kHitHeight);
    }
    final editedStarts = <Duration>[];
    var acc = Duration.zero;
    for (final c in clips) {
      editedStarts.add(acc);
      acc += c.editedLength;
    }
    final totalEditedX =
        acc.inMilliseconds / 1000.0 * pixelsPerSecond;
    final startTrim = clips.first.trimStart - clips.first.cutStart;
    final endTrim = clips.last.cutEnd - clips.last.trimEnd;

    // Collect every visible marker into a single list with its
    // semantic anchor x in content coords, then sort and lay them
    // out left-to-right pushing each one right if it would collide
    // with the previous marker's right edge. Each marker's triangle
    // gets an offset so it still points at its anchor even when the
    // body was pushed.
    final items = <_MarkerItem>[];
    if (startTrim > Duration.zero) {
      items.add(_MarkerItem(
        keyId: 'cut-marker-strip-start',
        anchorX: 0.0,
        hidden: startTrim,
        kind: _MarkerKind.startEdge,
        onTap: onClearStartTrim,
      ));
    }
    if (endTrim > Duration.zero) {
      items.add(_MarkerItem(
        keyId: 'cut-marker-strip-end',
        anchorX: totalEditedX,
        hidden: endTrim,
        kind: _MarkerKind.endEdge,
        onTap: onClearEndTrim,
      ));
    }
    for (var i = 0; i < clips.length - 1; i++) {
      final seamX = editedStarts[i + 1].inMilliseconds /
          1000.0 *
          pixelsPerSecond;
      // Routing is trim-driven (NOT total hidden including source
      // gap). A gap-only seam — created by deleting a slice between
      // two cuts — has no trim to restore, so the first click goes
      // straight to merge. The badge mirrors the routing: it reads
      // "Restore X.Xs" only when first click would actually restore
      // something.
      final trimmed = trimmedSecondsAtSeam(clips, i);
      items.add(_MarkerItem(
        keyId: 'cut-marker-strip-$i',
        anchorX: seamX,
        hidden: trimmed,
        kind: _MarkerKind.seam,
        seamIndex: i,
        onTap: () {
          if (trimmed > Duration.zero) {
            onClearSeamTrims(i);
          } else {
            onMergeSeam(i);
          }
        },
      ));
    }
    items.sort((a, b) => a.anchorX.compareTo(b.anchorX));

    // PASS 1 — sweep left→right, pushing right on collision. This
    // alone makes crowded markers at the START of the timeline
    // cascade neatly inward, but at the END it overshoots: the last
    // marker(s) get pushed past totalEditedX off the timeline.
    final lefts = <double>[];
    double? lastRight;
    for (final item in items) {
      var left = item.anchorX - CutMarker.kHitWidth / 2;
      if (item.kind == _MarkerKind.startEdge && left < 0) left = 0;
      if (item.kind == _MarkerKind.endEdge &&
          left > totalEditedX - CutMarker.kHitWidth) {
        left = totalEditedX - CutMarker.kHitWidth;
      }
      if (lastRight != null && left < lastRight) left = lastRight;
      lefts.add(left);
      lastRight = left + CutMarker.kHitWidth;
    }

    // PASS 2 — sweep right→left, capping each marker so it can't
    // extend past either the timeline's right edge (for the
    // rightmost marker) or its right neighbour's already-placed
    // left (for everyone else). This cascades the overshoot from
    // pass 1 back leftward — crowded markers near the END now stack
    // inward from the right edge instead of falling off the
    // timeline. Final clamp at 0 keeps the leftmost marker visible
    // even when there's so little room that a perfect non-overlap
    // is impossible.
    double? nextLeft;
    for (var i = items.length - 1; i >= 0; i--) {
      final allowedRight = nextLeft ?? totalEditedX;
      final allowedLeft = allowedRight - CutMarker.kHitWidth;
      if (lefts[i] > allowedLeft) lefts[i] = allowedLeft;
      if (lefts[i] < 0) lefts[i] = 0;
      nextLeft = lefts[i];
    }

    // PASS 3 — re-centre each touching cluster around the AVERAGE
    // of its members' anchors. After passes 1+2 a cluster sits
    // flush-packed but biased toward whichever side the cascade
    // came from; this shifts the whole cluster as a unit so it
    // floats around its own centre of mass instead of leaning. The
    // shift is clamped by the previous cluster's right edge on the
    // left and the next cluster's left edge (or totalEditedX) on
    // the right, so re-centring never re-introduces collisions.
    var i = 0;
    while (i < items.length) {
      var j = i;
      while (j + 1 < items.length &&
          (lefts[j + 1] - (lefts[j] + CutMarker.kHitWidth)).abs() < 0.5) {
        j++;
      }
      if (j > i) {
        final size = j - i + 1;
        var anchorSum = 0.0;
        for (var k = i; k <= j; k++) {
          anchorSum += items[k].anchorX;
        }
        final desiredCentre = anchorSum / size;
        final actualCentre =
            (lefts[i] + lefts[j] + CutMarker.kHitWidth) / 2;
        var delta = desiredCentre - actualCentre;
        if (delta != 0) {
          final leftBound =
              i > 0 ? lefts[i - 1] + CutMarker.kHitWidth : 0.0;
          final rightBound = j < items.length - 1
              ? lefts[j + 1] - CutMarker.kHitWidth
              : totalEditedX - CutMarker.kHitWidth;
          final maxLeftShift = lefts[i] - leftBound;
          final maxRightShift = rightBound - lefts[j];
          delta = delta.clamp(-maxLeftShift, maxRightShift);
          for (var k = i; k <= j; k++) {
            lefts[k] += delta;
          }
        }
      }
      i = j + 1;
    }

    final activeKey = _activeMarkerKey();
    final positioned = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isActive = activeKey != null && item.keyId == activeKey;
      positioned.add(Positioned(
        key: ValueKey(item.keyId),
        left: lefts[i],
        top: 0,
        width: CutMarker.kHitWidth,
        height: CutMarker.kHitHeight,
        child: CutMarker(
          hiddenSeconds: item.hidden,
          dragFade: dragging && !isActive,
          onTap: item.onTap,
        ),
      ));
    }

    return SizedBox(
      height: CutMarker.kHitHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: positioned,
      ),
    );
  }

  /// Returns the key of the marker that corresponds to the
  /// currently-dragging trim handle, or null if no drag is in
  /// flight. Used to exempt that one marker from the drag fade so
  /// the user sees it react in real time.
  String? _activeMarkerKey() {
    final info = activeDrag;
    if (info == null) return null;
    final i = info.sliceIndex;
    if (info.side == TrimSide.left) {
      // Left handle: trim sits on the seam between (i-1, i), or on
      // the START edge for slice 0.
      if (i == 0) return 'cut-marker-strip-start';
      return 'cut-marker-strip-${i - 1}';
    } else {
      // Right handle: trim sits on the seam between (i, i+1), or on
      // the END edge for the last slice.
      if (i == clips.length - 1) return 'cut-marker-strip-end';
      return 'cut-marker-strip-$i';
    }
  }
}

enum _MarkerKind { startEdge, endEdge, seam }

class _MarkerItem {
  _MarkerItem({
    required this.keyId,
    required this.anchorX,
    required this.hidden,
    required this.kind,
    required this.onTap,
    this.seamIndex,
  });

  final String keyId;
  final double anchorX;
  final Duration hidden;
  final _MarkerKind kind;
  final VoidCallback onTap;
  final int? seamIndex;
}
