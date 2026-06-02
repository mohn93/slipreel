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
class ClipLane extends StatelessWidget {
  const ClipLane({
    super.key,
    required this.clips,
    required this.selectedSliceIndex,
    required this.pixelsPerSecond,
    required this.cursorXListenable,
    required this.onSliceSelected,
    required this.onSliceTrimStartChanged,
    required this.onSliceTrimEndChanged,
  });

  final List<ClipSlice> clips;
  final int? selectedSliceIndex;
  final double pixelsPerSecond;
  final ValueListenable<double?> cursorXListenable;
  final ValueChanged<int?> onSliceSelected;
  final void Function(int sliceIndex, Duration trimStart) onSliceTrimStartChanged;
  final void Function(int sliceIndex, Duration trimEnd) onSliceTrimEndChanged;

  @override
  Widget build(BuildContext context) {
    // Walk the clips to compute each slice's edited-time start.
    final editedStarts = <Duration>[];
    var acc = Duration.zero;
    for (final c in clips) {
      editedStarts.add(acc);
      acc += c.effectiveLength;
    }

    return Stack(
      children: [
        for (var i = 0; i < clips.length; i++)
          Positioned(
            left: editedStarts[i].inMilliseconds / 1000.0 * pixelsPerSecond,
            top: 0,
            bottom: 0,
            child: SliceBar(
              slice: clips[i],
              sliceIndex: i,
              isSelected: selectedSliceIndex == i,
              pixelsPerSecond: pixelsPerSecond,
              editedStart: editedStarts[i],
              cursorXListenable: cursorXListenable,
              onSelectionToggle: (idx) {
                onSliceSelected(selectedSliceIndex == idx ? null : idx);
              },
              onTrimStartChanged: (v) => onSliceTrimStartChanged(i, v),
              onTrimEndChanged: (v) => onSliceTrimEndChanged(i, v),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              key: const ValueKey('clip-lane-seams'),
              painter: _SeamPainter(
                editedStarts: editedStarts,
                pixelsPerSecond: pixelsPerSecond,
              ),
            ),
          ),
        ),
      ],
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
