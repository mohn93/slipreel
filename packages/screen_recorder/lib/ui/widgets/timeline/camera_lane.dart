import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Pointer kinds accepted for pill body/edge drags. Trackpad pan is excluded
/// so two-finger scrolling over the lane still propagates to the timeline's
/// scroll view rather than dragging a pill.
const Set<PointerDeviceKind> _kPillDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// Camera lane in the editor timeline. Hosts camera regions as draggable
/// pills (no enter/exit ramps — simpler than [ZoomLane]), a hover-driven
/// ghost for click-to-add, and per-pill select/resize/delete gestures.
///
/// All public coordinates are in edited time; the lane maps to source time
/// internally at the rendering and drag-clamp seams (same as ZoomLane).
class CameraLane extends StatefulWidget {
  const CameraLane({
    super.key,
    required this.duration,
    required this.pixelsPerSecond,
    required this.contentWidth,
    required this.cameraRegions,
    required this.clips,
    this.selectedIndex,
    required this.onSeek,
    this.onCameraSelected,
    this.onCameraChanged,
    this.onCameraDeleted,
    this.onCameraAdded,
    this.trimDragging = false,
    this.animateLayout = true,
  });

  final Duration duration;
  final double pixelsPerSecond;
  final double contentWidth;

  /// Camera regions stored in source time.
  final List<CameraRegion> cameraRegions;

  /// Slice list — maps camera regions (source time) to the edited-time
  /// x-axis. Empty list means identity (single-clip / no-edit flow).
  final List<ClipSlice> clips;

  final int? selectedIndex;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<int?>? onCameraSelected;
  final void Function(int index, CameraRegion next)? onCameraChanged;
  final ValueChanged<int>? onCameraDeleted;
  final void Function(Duration start, Duration end)? onCameraAdded;

  /// True while any slice trim handle is being dragged. Snaps pill
  /// animation to zero so they track the live layout in real time.
  final bool trimDragging;

  /// Whether pill position/width changes should ease to their new geometry.
  final bool animateLayout;

  @override
  State<CameraLane> createState() => _CameraLaneState();
}

class _CameraLaneState extends State<CameraLane> {
  double? _hoverX;

  void _setHoverX(double? x) {
    if (_hoverX != x) setState(() => _hoverX = x);
  }

  Duration _sourceToEdited(Duration t) =>
      widget.clips.isEmpty ? t : sourceToEdited(widget.clips, t);
  Duration _editedToSource(Duration t) =>
      widget.clips.isEmpty ? t : editedToSource(widget.clips, t);

  ({Duration start, Duration end})? _ghostRange() =>
      _ghostRangeForX(_hoverX);

  ({Duration start, Duration end})? _ghostRangeForX(double? x) {
    if (x == null || widget.duration <= Duration.zero) return null;

    final pps = widget.pixelsPerSecond;
    final hoverTime = xToTime(x.clamp(0.0, widget.contentWidth), pps);

    // Hide ghost when hovering inside an existing camera region.
    for (final c in widget.cameraRegions) {
      final cStartE = _sourceToEdited(c.startTime);
      final cEndE = _sourceToEdited(c.endTime);
      if (hoverTime > cStartE && hoverTime < cEndE) return null;
    }

    // Find the gap [prevEnd, nextStart] surrounding hoverTime in edited time.
    var prevEnd = Duration.zero;
    var nextStart = widget.duration;
    for (final c in widget.cameraRegions) {
      final cStartE = _sourceToEdited(c.startTime);
      final cEndE = _sourceToEdited(c.endTime);
      if (cEndE <= hoverTime && cEndE > prevEnd) prevEnd = cEndE;
      if (cStartE >= hoverTime && cStartE < nextStart) nextStart = cStartE;
    }

    final gap = nextStart - prevEnd;
    if (gap < kGhostMinSpan) return null;

    final span = gap < kGhostZoomSpan ? gap : kGhostZoomSpan;

    // Mouse-x = ghost left edge; clamp so it doesn't bleed past neighbors.
    var start = hoverTime;
    var end = start + span;
    if (end > nextStart) {
      end = nextStart;
      start = end - span;
    }
    if (start < prevEnd) {
      start = prevEnd;
      end = start + span;
    }
    return (start: start, end: end);
  }

  ({Duration? prevEnd, Duration? nextStart}) _neighborsOf(int i) {
    Duration? prev;
    Duration? next;
    final regions = widget.cameraRegions;
    for (var j = 0; j < regions.length; j++) {
      if (j == i) continue;
      final c = regions[j];
      if (c.endTime <= regions[i].startTime) {
        if (prev == null || c.endTime > prev) prev = c.endTime;
      } else if (c.startTime >= regions[i].endTime) {
        if (next == null || c.startTime < next) next = c.startTime;
      }
    }
    return (prevEnd: prev, nextStart: next);
  }

  @override
  Widget build(BuildContext context) {
    final ghost = _ghostRange();

    return MouseRegion(
      opaque: false,
      onHover: (e) => _setHoverX(e.localPosition.dx),
      onExit: (_) => _setHoverX(null),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Background tap area: commit ghost add or deselect.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final x = d.localPosition.dx.clamp(0.0, widget.contentWidth);
                final g = _ghostRangeForX(x);
                if (g != null && widget.onCameraAdded != null) {
                  widget.onCameraAdded!(
                    _editedToSource(g.start),
                    _editedToSource(g.end),
                  );
                  return;
                }
                widget.onCameraSelected?.call(null);
              },
              child: const SizedBox.expand(),
            ),
          ),
          // Empty-state hint.
          if (widget.cameraRegions.isEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _EmptyCameraLaneHint(hovered: _hoverX != null),
                ),
              ),
            ),
          // Ghost add preview.
          if (ghost != null)
            _CameraGhost(
              start: ghost.start,
              end: ghost.end,
              pixelsPerSecond: widget.pixelsPerSecond,
            ),
          // Camera pills.
          for (var i = 0; i < widget.cameraRegions.length; i++)
            _CameraPill(
              key: ValueKey(i),
              index: i,
              region: widget.cameraRegions[i],
              isSelected: widget.selectedIndex == i,
              duration: widget.duration,
              pixelsPerSecond: widget.pixelsPerSecond,
              contentWidth: widget.contentWidth,
              clips: widget.clips,
              neighbors: _neighborsOf(i),
              onSeek: widget.onSeek,
              onChanged: widget.onCameraChanged,
              onSelected: widget.onCameraSelected,
              onDeleted: widget.onCameraDeleted,
              trimDragging: widget.trimDragging,
              animateLayout: widget.animateLayout,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ghost preview
// ---------------------------------------------------------------------------

class _CameraGhost extends StatelessWidget {
  const _CameraGhost({
    required this.start,
    required this.end,
    required this.pixelsPerSecond,
  });

  final Duration start;
  final Duration end;
  final double pixelsPerSecond;

  @override
  Widget build(BuildContext context) {
    final left = timeToX(start, pixelsPerSecond);
    final width = timeToX(end, pixelsPerSecond) - left;
    final showAddIcon = width >= 28;
    return Positioned(
      left: left,
      top: zoomPillInset,
      width: width,
      height: laneHeight - zoomPillInset * 2,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: cameraGhostFill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cameraGhostStroke, width: 1),
          ),
          alignment: Alignment.center,
          child: showAddIcon
              ? const Icon(Icons.add, size: 18, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pill
// ---------------------------------------------------------------------------

enum _CameraDragMode { none, body, leftEdge, rightEdge }

class _CameraPill extends StatefulWidget {
  const _CameraPill({
    super.key,
    required this.index,
    required this.region,
    required this.isSelected,
    required this.duration,
    required this.pixelsPerSecond,
    required this.contentWidth,
    required this.clips,
    required this.neighbors,
    required this.onSeek,
    this.onChanged,
    this.onSelected,
    this.onDeleted,
    this.trimDragging = false,
    this.animateLayout = true,
  });

  final int index;
  final CameraRegion region;
  final bool isSelected;
  final Duration duration;
  final double pixelsPerSecond;
  final double contentWidth;
  final List<ClipSlice> clips;
  final ({Duration? prevEnd, Duration? nextStart}) neighbors;
  final ValueChanged<Duration> onSeek;
  final void Function(int, CameraRegion)? onChanged;
  final ValueChanged<int?>? onSelected;
  final ValueChanged<int>? onDeleted;
  final bool trimDragging;
  final bool animateLayout;

  @override
  State<_CameraPill> createState() => _CameraPillState();
}

class _CameraPillState extends State<_CameraPill> {
  _CameraDragMode _mode = _CameraDragMode.none;
  late Duration _dragStartTime;
  late Duration _dragEndTime;
  double _dxAccum = 0;
  bool _hovered = false;

  Duration _sourceToEdited(Duration t) =>
      widget.clips.isEmpty ? t : sourceToEdited(widget.clips, t);
  Duration _editedToSource(Duration t) =>
      widget.clips.isEmpty ? t : editedToSource(widget.clips, t);

  double get _startX =>
      timeToX(_sourceToEdited(widget.region.startTime), widget.pixelsPerSecond);
  double get _endX =>
      timeToX(_sourceToEdited(widget.region.endTime), widget.pixelsPerSecond);

  Duration get _minStart => widget.neighbors.prevEnd ?? Duration.zero;
  Duration get _maxEnd => widget.neighbors.nextStart ?? widget.duration;
  Duration get _minDuration =>
      const Duration(milliseconds: minCameraDurationMs);

  void _beginMode(_CameraDragMode mode) {
    _dxAccum = 0;
    _dragStartTime = widget.region.startTime;
    _dragEndTime = widget.region.endTime;
    _mode = mode;
    widget.onSelected?.call(widget.index);
  }

  void _endDrag() {
    setState(() {
      _mode = _CameraDragMode.none;
      _dxAccum = 0;
    });
  }

  void _update(double dxDelta) {
    if (widget.onChanged == null) return;
    _dxAccum += dxDelta;
    // 1 px = duration / contentWidth microseconds (same scale as ZoomLane)
    final scale = widget.duration.inMicroseconds / widget.contentWidth;
    final deltaUs = (_dxAccum * scale).round();
    final delta = Duration(microseconds: deltaUs);

    // Operate in edited space for clamping, then map back to source.
    final editedDragStart = _sourceToEdited(_dragStartTime);
    final editedDragEnd = _sourceToEdited(_dragEndTime);
    final editedMinStart = _sourceToEdited(_minStart);
    final editedMaxEnd = _sourceToEdited(_maxEnd);

    var editedNextStart = editedDragStart;
    var editedNextEnd = editedDragEnd;

    switch (_mode) {
      case _CameraDragMode.body:
        editedNextStart = editedDragStart + delta;
        editedNextEnd = editedDragEnd + delta;
        final span = editedNextEnd - editedNextStart;
        if (editedNextStart < editedMinStart) {
          editedNextStart = editedMinStart;
          editedNextEnd = editedNextStart + span;
        }
        if (editedNextEnd > editedMaxEnd) {
          editedNextEnd = editedMaxEnd;
          editedNextStart = editedNextEnd - span;
        }
      case _CameraDragMode.leftEdge:
        editedNextStart = editedDragStart + delta;
        if (editedNextStart < editedMinStart) {
          editedNextStart = editedMinStart;
        }
        if (editedNextEnd - editedNextStart < _minDuration) {
          editedNextStart = editedNextEnd - _minDuration;
        }
      case _CameraDragMode.rightEdge:
        editedNextEnd = editedDragEnd + delta;
        if (editedNextEnd > editedMaxEnd) editedNextEnd = editedMaxEnd;
        if (editedNextEnd - editedNextStart < _minDuration) {
          editedNextEnd = editedNextStart + _minDuration;
        }
      case _CameraDragMode.none:
        return;
    }

    final nextStart = _editedToSource(editedNextStart);
    final nextEnd = _editedToSource(editedNextEnd);

    widget.onChanged!(
      widget.index,
      widget.region.copyWith(
        startTime: nextStart,
        duration: nextEnd - nextStart,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final left = _startX;
    final pillWidth = (_endX - _startX).clamp(
      handleHitWidth * 2,
      double.infinity,
    );
    final pillBodyHeight = laneHeight - zoomPillInset * 2;
    final fill = widget.isSelected ? cameraFillSelected : cameraFill;
    final stroke = widget.isSelected ? Colors.white : cameraStroke;

    return AnimatedPositioned(
      duration: widget.trimDragging || !widget.animateLayout
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: left,
      top: zoomPillInset,
      width: pillWidth,
      height: pillBodyHeight,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Pill body — tap to select, drag to translate.
            Positioned.fill(
              child: MouseRegion(
                key: Key('camera-pill-${widget.index}'),
                cursor: _mode == _CameraDragMode.body
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.opaque,
                  gestures: <Type, GestureRecognizerFactory>{
                    TapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          TapGestureRecognizer
                        >(() => TapGestureRecognizer(), (instance) {
                          instance.onTapDown = (_) =>
                              widget.onSelected?.call(widget.index);
                        }),
                    HorizontalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          HorizontalDragGestureRecognizer
                        >(
                          () => HorizontalDragGestureRecognizer(
                            supportedDevices: _kPillDragDevices,
                          ),
                          (instance) {
                            instance
                              ..onStart =
                                  ((_) => _beginMode(_CameraDragMode.body))
                              ..onUpdate = ((d) => _update(d.delta.dx))
                              ..onEnd = ((_) => _endDrag())
                              ..onCancel = _endDrag;
                          },
                        ),
                  },
                  child: _CameraPillBody(
                    fill: fill,
                    stroke: stroke,
                    isSelected: widget.isSelected,
                    width: pillWidth,
                  ),
                ),
              ),
            ),
            // Left resize handle.
            Positioned(
              left: 0,
              top: 0,
              width: handleHitWidth,
              height: pillBodyHeight,
              child: _PillEdgeHandle(
                alignment: Alignment.centerLeft,
                showHandle: _hovered,
                onDragStart: () => _beginMode(_CameraDragMode.leftEdge),
                onDragUpdate: _update,
                onDragEnd: _endDrag,
                onTap: () => widget.onSelected?.call(widget.index),
              ),
            ),
            // Right resize handle.
            Positioned(
              right: 0,
              top: 0,
              width: handleHitWidth,
              height: pillBodyHeight,
              child: _PillEdgeHandle(
                alignment: Alignment.centerRight,
                showHandle: _hovered,
                onDragStart: () => _beginMode(_CameraDragMode.rightEdge),
                onDragUpdate: _update,
                onDragEnd: _endDrag,
                onTap: () => widget.onSelected?.call(widget.index),
              ),
            ),
            // Delete button (hover-revealed, top-right corner).
            if (_hovered && widget.onDeleted != null)
              Positioned(
                top: -6,
                right: -6,
                child: _CameraDeleteButton(
                  onPressed: () => widget.onDeleted!(widget.index),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pill body painter (simple — no ramps)
// ---------------------------------------------------------------------------

class _CameraPillBody extends StatelessWidget {
  const _CameraPillBody({
    required this.fill,
    required this.stroke,
    required this.isSelected,
    required this.width,
  });

  final Color fill;
  final Color stroke;
  final bool isSelected;
  final double width;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CameraPillPainter(
        fill: fill,
        stroke: stroke,
        isSelected: isSelected,
      ),
      child: width >= 36
          ? const Center(
              child: Icon(Icons.videocam, size: 16, color: Colors.white70),
            )
          : null,
    );
  }
}

class _CameraPillPainter extends CustomPainter {
  _CameraPillPainter({
    required this.fill,
    required this.stroke,
    required this.isSelected,
  });

  final Color fill;
  final Color stroke;
  final bool isSelected;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));

    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            fill.withValues(alpha: 0.85),
            fill,
          ],
        ).createShader(rect),
    );

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 1.5 : 1
        ..color = stroke,
    );
  }

  @override
  bool shouldRepaint(_CameraPillPainter old) =>
      old.fill != fill || old.stroke != stroke || old.isSelected != isSelected;
}

// ---------------------------------------------------------------------------
// Edge handle (copied from ZoomLane's _PillEdgeHandle — same interaction)
// ---------------------------------------------------------------------------

class _PillEdgeHandle extends StatefulWidget {
  const _PillEdgeHandle({
    required this.alignment,
    required this.showHandle,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  final Alignment alignment;
  final bool showHandle;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;

  @override
  State<_PillEdgeHandle> createState() => _PillEdgeHandleState();
}

class _PillEdgeHandleState extends State<_PillEdgeHandle> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final emphasized = _hover || _dragging;
    final visible = widget.showHandle || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (instance) {
                  instance.onTapDown = (_) => widget.onTap();
                },
              ),
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(
                () => HorizontalDragGestureRecognizer(
                  supportedDevices: _kPillDragDevices,
                ),
                (instance) {
                  instance
                    ..onStart = ((_) {
                      setState(() => _dragging = true);
                      widget.onDragStart();
                    })
                    ..onUpdate = ((d) => widget.onDragUpdate(d.delta.dx))
                    ..onEnd = ((_) {
                      setState(() => _dragging = false);
                      widget.onDragEnd();
                    })
                    ..onCancel = (() {
                      setState(() => _dragging = false);
                      widget.onDragEnd();
                    });
                },
              ),
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Align(
            alignment: widget.alignment,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: emphasized ? 4 : 3,
              decoration: BoxDecoration(
                color: !visible
                    ? Colors.transparent
                    : (emphasized
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.30)),
                borderRadius: BorderRadius.circular(4),
                boxShadow: emphasized && visible
                    ? const [
                        BoxShadow(
                          color: Color(0xCC000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                        BoxShadow(
                          color: Color(0x803FBCC6),
                          blurRadius: 8,
                          spreadRadius: 0.5,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Delete button
// ---------------------------------------------------------------------------

class _CameraDeleteButton extends StatelessWidget {
  const _CameraDeleteButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: const Color(0xFFE5484D),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.close, size: 12, color: Colors.white),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty-state hint
// ---------------------------------------------------------------------------

class _EmptyCameraLaneHint extends StatelessWidget {
  const _EmptyCameraLaneHint({required this.hovered});

  final bool hovered;

  static const Duration _anim = Duration(milliseconds: 220);
  static const Curve _curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    final restColor = const Color(0xFFFFFFFF).withValues(alpha: 0.03);
    final hoverColor = const Color(0xFF3FBCC6).withValues(alpha: 0.08);
    final restBorder = const Color(0xFFFFFFFF).withValues(alpha: 0.08);
    final hoverBorder = const Color(0xFF3FBCC6).withValues(alpha: 0.45);
    final restText = const Color(0xFFAAAAB5).withValues(alpha: 0.65);
    final hoverText = const Color(0xFFD0F5F7);

    return AnimatedContainer(
      duration: _anim,
      curve: _curve,
      padding: EdgeInsets.symmetric(
        horizontal: hovered ? 14 : 12,
        vertical: hovered ? 7 : 6,
      ),
      decoration: BoxDecoration(
        color: hovered ? hoverColor : restColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: hovered ? hoverBorder : restBorder, width: 1),
        boxShadow: hovered
            ? const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : const [],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            scale: hovered ? 1.0 : 0.85,
            duration: _anim,
            curve: _curve,
            child: Icon(
              Icons.videocam_outlined,
              size: 14,
              color: hovered ? hoverText : restText,
            ),
          ),
          const SizedBox(width: 6),
          AnimatedDefaultTextStyle(
            duration: _anim,
            curve: _curve,
            style: TextStyle(
              color: hovered ? hoverText : restText,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
            ),
            child: const Text('Click to add camera region'),
          ),
        ],
      ),
    );
  }
}
