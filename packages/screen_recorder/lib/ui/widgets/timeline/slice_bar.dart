import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// One slice's rendering on the clip lane. Handles its own trim drags,
/// selection toggle, chevron-notch visibility on trimmed sides, and
/// the magnetic-pull transform driven by the cut overlay's cursor x.
class SliceBar extends StatefulWidget {
  const SliceBar({
    super.key,
    required this.slice,
    required this.sliceIndex,
    required this.isSelected,
    required this.pixelsPerSecond,
    required this.editedStart,
    required this.cursorXListenable,
    required this.onSelectionToggle,
    required this.onTrimStartChanged,
    required this.onTrimEndChanged,
  });

  final ClipSlice slice;
  final int sliceIndex;
  final bool isSelected;
  final double pixelsPerSecond;
  final Duration editedStart;
  final ValueListenable<double?> cursorXListenable;
  final ValueChanged<int> onSelectionToggle;
  final ValueChanged<Duration> onTrimStartChanged;
  final ValueChanged<Duration> onTrimEndChanged;

  @override
  State<SliceBar> createState() => _SliceBarState();
}

class _SliceBarState extends State<SliceBar> {
  // Anchors capture both the trim Duration AND the gesture's starting
  // global x at drag-start. Computing each update against the start
  // position (rather than accumulating frame-by-frame deltas) avoids
  // losing the pre-slop pixels that the gesture arena consumes before
  // the first update fires.
  Duration? _trimStartAnchor;
  Duration? _trimEndAnchor;
  double? _dragStartGlobalX;

  double get _widthPx =>
      widget.slice.effectiveLength.inMilliseconds / 1000.0 * widget.pixelsPerSecond;
  double get _editedStartPx =>
      widget.editedStart.inMilliseconds / 1000.0 * widget.pixelsPerSecond;

  void _onLeftDragStart(DragStartDetails d) {
    _trimStartAnchor = widget.slice.trimStart;
    _dragStartGlobalX = d.globalPosition.dx;
  }

  void _onLeftDragUpdate(DragUpdateDetails d) {
    final anchor = _trimStartAnchor;
    final startX = _dragStartGlobalX;
    if (anchor == null || startX == null) return;
    final deltaSec = (d.globalPosition.dx - startX) / widget.pixelsPerSecond;
    final next = anchor + Duration(microseconds: (deltaSec * 1e6).round());
    widget.onTrimStartChanged(next);
  }

  void _onRightDragStart(DragStartDetails d) {
    _trimEndAnchor = widget.slice.trimEnd;
    _dragStartGlobalX = d.globalPosition.dx;
  }

  void _onRightDragUpdate(DragUpdateDetails d) {
    final anchor = _trimEndAnchor;
    final startX = _dragStartGlobalX;
    if (anchor == null || startX == null) return;
    final deltaSec = (d.globalPosition.dx - startX) / widget.pixelsPerSecond;
    final next = anchor + Duration(microseconds: (deltaSec * 1e6).round());
    widget.onTrimEndChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final sliceCenterX = _editedStartPx + _widthPx / 2;
    return ValueListenableBuilder<double?>(
      valueListenable: widget.cursorXListenable,
      builder: (_, cursorX, child) {
        final pull = computeMagneticPull(
          cursorX: cursorX,
          sliceCenterX: sliceCenterX,
        );
        return Transform.translate(
          offset: Offset(pull, 0),
          child: child,
        );
      },
      child: GestureDetector(
        onTap: () => widget.onSelectionToggle(widget.sliceIndex),
        child: Stack(
          children: [
            Container(
              width: _widthPx,
              height: laneHeight,
              decoration: BoxDecoration(
                color: widget.isSelected ? clipFillTop : clipFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: clipStroke),
              ),
            ),
            if (widget.slice.isLeftTrimmed)
              const Positioned(
                key: ValueKey('slice-bar-left-chevron'),
                left: 0,
                top: 0,
                bottom: 0,
                child: _ChevronNotch(pointsRight: false),
              ),
            if (widget.slice.isRightTrimmed)
              const Positioned(
                key: ValueKey('slice-bar-right-chevron'),
                right: 0,
                top: 0,
                bottom: 0,
                child: _ChevronNotch(pointsRight: true),
              ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: handleHitWidth,
              child: GestureDetector(
                key: const ValueKey('slice-bar-left-handle'),
                behavior: HitTestBehavior.translucent,
                // dragStartBehavior.down so the slop pixels are
                // delivered as part of the first update, not silently
                // eaten by the gesture arena win.
                dragStartBehavior: DragStartBehavior.down,
                onHorizontalDragStart: _onLeftDragStart,
                onHorizontalDragUpdate: _onLeftDragUpdate,
                child: const MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: SizedBox.expand(),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: handleHitWidth,
              child: GestureDetector(
                key: const ValueKey('slice-bar-right-handle'),
                behavior: HitTestBehavior.translucent,
                dragStartBehavior: DragStartBehavior.down,
                onHorizontalDragStart: _onRightDragStart,
                onHorizontalDragUpdate: _onRightDragUpdate,
                child: const MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-level so the magnetic-pull math is unit-testable without
/// constructing a widget tree. Used by [SliceBar].
double computeMagneticPull({
  required double? cursorX,
  required double sliceCenterX,
}) {
  if (cursorX == null) return 0;
  final dx = cursorX - sliceCenterX;
  final abs = dx.abs();
  if (abs > 80) return 0;
  final proximity = (1 - abs / 80).clamp(0.0, 1.0);
  return dx.sign * proximity * proximity * 6;
}

class _ChevronNotch extends StatelessWidget {
  const _ChevronNotch({required this.pointsRight});
  final bool pointsRight;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        pointsRight ? Icons.chevron_right : Icons.chevron_left,
        color: const Color(0xFF6C63FF), // kInspectorAccent
        size: 14,
      ),
    );
  }
}
