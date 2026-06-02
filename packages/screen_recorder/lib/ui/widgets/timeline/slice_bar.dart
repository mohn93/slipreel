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

  // The slice is rendered in EDITED time on the timeline, so 1 pixel
  // corresponds to `1 / pixelsPerSecond` edited seconds. The underlying
  // trim bounds live in SOURCE time, so converting a pixel delta back to
  // a trim delta multiplies by playbackSpeed (1 edited-second of drag =
  // `speed` source-seconds of trim movement at the slice's speed).
  double get _widthPx =>
      widget.slice.editedLength.inMilliseconds / 1000.0 * widget.pixelsPerSecond;
  double get _editedStartPx =>
      widget.editedStart.inMilliseconds / 1000.0 * widget.pixelsPerSecond;
  double get _sourceSecondsPerPixel {
    if (widget.pixelsPerSecond <= 0) return 0;
    final speed =
        widget.slice.playbackSpeed > 0 ? widget.slice.playbackSpeed : 1.0;
    return speed / widget.pixelsPerSecond;
  }

  void _onLeftDragStart(DragStartDetails d) {
    _trimStartAnchor = widget.slice.trimStart;
    _dragStartGlobalX = d.globalPosition.dx;
  }

  void _onLeftDragUpdate(DragUpdateDetails d) {
    final anchor = _trimStartAnchor;
    final startX = _dragStartGlobalX;
    if (anchor == null || startX == null) return;
    final deltaSec = (d.globalPosition.dx - startX) * _sourceSecondsPerPixel;
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
    final deltaSec = (d.globalPosition.dx - startX) * _sourceSecondsPerPixel;
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
              key: const ValueKey('slice-bar-body'),
              width: _widthPx,
              height: laneHeight,
              decoration: BoxDecoration(
                color: widget.isSelected ? clipFillTop : clipFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: clipStroke),
              ),
            ),
            // Tick marks every 0.5s of SOURCE time. The slice is rendered
            // in edited time (compressed by speed), so 0.5s of source
            // becomes 0.5/speed of edited width — at 2x speed the ticks
            // sit half as far apart, giving a "this slice plays fast"
            // visual rhythm. Source 0.5s also matches a natural cue —
            // tick density corresponds to recording-time half-seconds.
            if (_widthPx >= 48)
              Positioned(
                left: 0,
                top: 0,
                width: _widthPx,
                height: laneHeight,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _SliceTickPainter(
                      widthPx: _widthPx,
                      sourceSeconds:
                          widget.slice.effectiveLength.inMilliseconds / 1000.0,
                    ),
                  ),
                ),
              ),
            // "Clip · Ns · 1x" label centered inside the body, only when
            // wide enough not to feel cramped.
            if (_widthPx >= 80)
              Positioned(
                left: 0,
                top: 0,
                width: _widthPx,
                height: laneHeight,
                child: IgnorePointer(
                  child: _SliceLabel(
                    editedLength: widget.slice.editedLength,
                    playbackSpeed: widget.slice.playbackSpeed,
                    wide: _widthPx >= 140,
                  ),
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

/// Paints faint vertical tick marks every 0.5s of SOURCE time inside
/// the slice body. The slice is rendered in edited time (compressed by
/// playbackSpeed), so denser source content packs ticks closer together
/// — a "this slice plays fast" visual rhythm. Doubles the interval
/// (1s, 2s, ...) when ticks would land closer than 8px to avoid moiré.
class _SliceTickPainter extends CustomPainter {
  const _SliceTickPainter({
    required this.widthPx,
    required this.sourceSeconds,
  });

  final double widthPx;
  final double sourceSeconds;

  static const double _intervalSec = 0.5;
  static const double _minSpacingPx = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (sourceSeconds <= 0 || widthPx <= 0) return;
    final pxPerSourceSec = widthPx / sourceSeconds;
    var step = _intervalSec;
    while (step * pxPerSourceSec < _minSpacingPx) {
      step *= 2;
      if (step > sourceSeconds) return;
    }
    final paint = Paint()
      ..color = clipStroke.withValues(alpha: 0.32)
      ..strokeWidth = 1;
    final inset = 4.0;
    var t = step;
    while (t < sourceSeconds) {
      final x = t * pxPerSourceSec;
      canvas.drawLine(
        Offset(x, inset),
        Offset(x, size.height - inset),
        paint,
      );
      t += step;
    }
  }

  @override
  bool shouldRepaint(_SliceTickPainter old) =>
      old.widthPx != widthPx || old.sourceSeconds != sourceSeconds;
}

/// Centered "Clip / Ns · 1x" badge inside the slice body. [wide] toggles
/// the "Clip" caption row — narrow slices show only the duration+speed
/// line so the text doesn't overflow.
class _SliceLabel extends StatelessWidget {
  const _SliceLabel({
    required this.editedLength,
    required this.playbackSpeed,
    required this.wide,
  });

  final Duration editedLength;
  final double playbackSpeed;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final secs = editedLength.inMilliseconds / 1000.0;
    final durLabel = secs >= 10
        ? '${secs.round()}s'
        : '${secs.toStringAsFixed(1)}s';
    final speedLabel = playbackSpeed == playbackSpeed.roundToDouble()
        ? '${playbackSpeed.toInt()}x'
        : '${playbackSpeed.toStringAsFixed(1)}x';
    final captionStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.55),
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
    );
    const valueStyle = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wide) Text('Clip', style: captionStyle),
          if (wide) const SizedBox(height: 1),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(durLabel, style: valueStyle),
              const SizedBox(width: 6),
              Icon(
                Icons.timer_outlined,
                size: 11,
                color: Colors.white.withValues(alpha: 0.65),
              ),
              const SizedBox(width: 6),
              Text(speedLabel, style: valueStyle),
            ],
          ),
        ],
      ),
    );
  }
}
