import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Multi-slice clip lane. Lays slices end-to-end in EDITED time (so
/// trimmed-away source regions disappear visually); paints thin seams
/// between adjacent slices; delegates per-slice rendering to
/// [SliceBar]; routes selection toggles up to the parent so the
/// inspector can swap to the slice editor for that slice.
///
/// While a trim handle is being dragged, the active slice's "bloom"
/// (cutSpan reveal + dim bands) needs to render above its siblings.
/// We track [_draggingIndex] internally so we can both dim the other
/// slices and reorder children so the dragging slice paints last.
class ClipLane extends StatefulWidget {
  const ClipLane({
    super.key,
    required this.clips,
    required this.selectedSliceIndex,
    required this.pixelsPerSecond,
    required this.onSliceSelected,
    required this.onSliceTrimStartChanged,
    required this.onSliceTrimEndChanged,
    this.onTrimDragChanged,
  });

  final List<ClipSlice> clips;
  final int? selectedSliceIndex;
  final double pixelsPerSecond;
  final ValueChanged<int?> onSliceSelected;
  final void Function(int sliceIndex, Duration trimStart) onSliceTrimStartChanged;
  final void Function(int sliceIndex, Duration trimEnd) onSliceTrimEndChanged;
  // Fires true the moment ANY slice's trim handle starts being
  // dragged, and false once it ends/cancels. Lets the parent fade
  // out distractions (playhead, hover indicator) while a trim drag
  // is in flight, then fade them back in.
  final ValueChanged<bool>? onTrimDragChanged;

  @override
  State<ClipLane> createState() => _ClipLaneState();
}

class _ClipLaneState extends State<ClipLane> {
  // Index of the slice whose trim handle is currently being dragged
  // (set on drag start, cleared on drag end/cancel). Drives both the
  // dim-others overlay and z-reordering so the bloom is never hidden
  // behind an adjacent slice. Selection alone does NOT trigger this —
  // we want a click-to-select to keep the regular highlight.
  int? _draggingIndex;

  static const Duration _dimDuration = Duration(milliseconds: 220);
  // Three opacity tiers for non-foregrounded slices:
  // - drag in progress      → 0.4  (heavy: dim siblings recede)
  // - selection (no drag)   → 0.7  (subtle: lets the selected slice
  //                                  read brighter so the neighbour
  //                                  halo bleed becomes visible)
  // - no selection / drag   → 1.0  (resting)
  static const double _dragDimOpacity = 0.4;
  static const double _selectionDimOpacity = 0.7;

  @override
  Widget build(BuildContext context) {
    // Walk the clips to compute each slice's edited-time start. Use
    // editedLength (effective length / playbackSpeed) so a 30s slice
    // at 2x lays out as 15s wide — the ruler shows output duration,
    // faster slices visually compress.
    final editedStarts = <Duration>[];
    var acc = Duration.zero;
    for (final c in widget.clips) {
      editedStarts.add(acc);
      acc += c.editedLength;
    }

    final hasDrag =
        _draggingIndex != null && _draggingIndex! < widget.clips.length;
    final selectedIdx = widget.selectedSliceIndex;
    final hasSelection =
        selectedIdx != null && selectedIdx < widget.clips.length;

    // Slices that must paint on top of the regular stack — either to
    // keep the selection ring/halo from being clipped by the next
    // slice's body, or to keep the drag bloom above its dim siblings.
    // Order: selected (if distinct from dragging) first, then the
    // dragging slice on top of even the selected one.
    final topIndices = <int>[];
    if (hasSelection && selectedIdx != _draggingIndex) {
      topIndices.add(selectedIdx);
    }
    if (hasDrag) topIndices.add(_draggingIndex!);
    final topSet = topIndices.toSet();

    // Background-slice opacity picks the heaviest applicable dim tier.
    final double bgOpacity = hasDrag
        ? _dragDimOpacity
        : (hasSelection ? _selectionDimOpacity : 1.0);

    return Stack(
      // Clip.none so the selected/dragging SliceBar's selection ring,
      // neighbour halos, and expanded dim bands can spill outside the
      // lane's bounds.
      clipBehavior: Clip.none,
      children: [
        // Pass 1: regular slices, dimmed according to bgOpacity.
        for (var i = 0; i < widget.clips.length; i++)
          if (!topSet.contains(i))
            _buildSlice(i, editedStarts[i], opacity: bgOpacity),
        // Seams between adjacent slices, painted above regular bodies
        // but below the foregrounded slice(s).
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              key: const ValueKey('clip-lane-seams'),
              painter: _SeamPainter(
                editedStarts: editedStarts,
                pixelsPerSecond: widget.pixelsPerSecond,
              ),
            ),
          ),
        ),
        // Pass 2: selected/dragging slice(s) on top so the selection
        // ring + neighbour halos render above the next slice's body.
        for (final i in topIndices)
          _buildSlice(i, editedStarts[i], opacity: 1.0),
      ],
    );
  }

  Widget _buildSlice(int i, Duration editedStart, {required double opacity}) {
    final left = editedStart.inMilliseconds / 1000.0 * widget.pixelsPerSecond;
    return Positioned(
      key: ValueKey('clip-lane-slice-$i'),
      left: left,
      top: 0,
      bottom: 0,
      child: AnimatedOpacity(
        duration: _dimDuration,
        curve: Curves.easeOut,
        opacity: opacity,
        child: SliceBar(
          slice: widget.clips[i],
          sliceIndex: i,
          isSelected: widget.selectedSliceIndex == i,
          // Neighbour halos: slice i+1 lights its LEFT edge if i is
          // selected, and slice i-1 lights its RIGHT edge — visually
          // the selected slice's halo bleeds into the touching ends
          // of its immediate neighbours.
          glowLeft: widget.selectedSliceIndex != null &&
              i == widget.selectedSliceIndex! + 1,
          glowRight: widget.selectedSliceIndex != null &&
              i == widget.selectedSliceIndex! - 1,
          pixelsPerSecond: widget.pixelsPerSecond,
          editedStart: editedStart,
          onSelectionToggle: (idx) {
            widget.onSliceSelected(
                widget.selectedSliceIndex == idx ? null : idx);
          },
          onTrimStartChanged: (v) => widget.onSliceTrimStartChanged(i, v),
          onTrimEndChanged: (v) => widget.onSliceTrimEndChanged(i, v),
          onTrimDragChanged: (active) {
            final next = active ? i : (_draggingIndex == i ? null : _draggingIndex);
            if (next != _draggingIndex) {
              final wasActive = _draggingIndex != null;
              final nowActive = next != null;
              setState(() => _draggingIndex = next);
              if (wasActive != nowActive) {
                widget.onTrimDragChanged?.call(nowActive);
              }
            }
          },
        ),
      ),
    );
  }
}

class _SeamPainter extends CustomPainter {
  _SeamPainter({
    required this.editedStarts,
    required this.pixelsPerSecond,
  });

  final List<Duration> editedStarts;
  final double pixelsPerSecond;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = trackBg
      ..strokeWidth = kClipSeamWidth;
    // First entry is always Duration.zero (no seam before the first
    // slice); start at index 1 to draw seams between adjacent slices.
    for (var i = 1; i < editedStarts.length; i++) {
      final x = editedStarts[i].inMilliseconds / 1000.0 * pixelsPerSecond;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  // ClipLane allocates a fresh List<Duration> every build, so identity
  // comparison would force a repaint per frame. Compare content instead;
  // editedStarts is derived from clip.effectiveLength so it captures
  // every clip change that moves a seam.
  @override
  bool shouldRepaint(_SeamPainter old) =>
      old.pixelsPerSecond != pixelsPerSecond ||
      !listEquals(old.editedStarts, editedStarts);
}
