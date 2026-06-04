import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// The bottom lane in the editor timeline: hosts zoom regions as draggable
/// pills, a hover-driven "click to add" ghost in the empty area, and routes
/// per-zoom edit gestures (drag body / drag edges / drag ramp dividers /
/// step zoom level / delete) to the parent.
///
/// All public coordinates are in edited time; the lane maps to source time
/// internally at the rendering and drag-clamp seams.
class ZoomLane extends StatefulWidget {
  const ZoomLane({
    super.key,
    required this.duration,
    required this.pixelsPerSecond,
    required this.contentWidth,
    required this.zoomRegions,
    required this.clips,
    required this.onSeek,
    this.selectedIndex,
    this.onZoomChanged,
    this.onZoomSelected,
    this.onZoomDeleted,
    this.onZoomAdded,
  });

  final Duration duration;
  final double pixelsPerSecond;
  final double contentWidth;
  final List<ZoomRegion> zoomRegions;

  /// Slice list — needed to map zoom regions (stored in source time)
  /// to the timeline's edited-time x-axis. Empty list means identity
  /// (legacy single-clip flow).
  final List<ClipSlice> clips;

  final ValueChanged<Duration> onSeek;
  final int? selectedIndex;
  final void Function(int, ZoomRegion)? onZoomChanged;
  final ValueChanged<int?>? onZoomSelected;
  final ValueChanged<int>? onZoomDeleted;
  final void Function(Duration start, Duration end)? onZoomAdded;

  @override
  State<ZoomLane> createState() => _ZoomLaneState();
}

class _ZoomLaneState extends State<ZoomLane> {
  /// Last hovered x within the lane, in lane-local pixels. Null when
  /// the cursor is outside the lane.
  double? _hoverX;

  void _setHoverX(double? x) {
    if (_hoverX != x) setState(() => _hoverX = x);
  }

  /// Compute the ghost zoom range for the current hover position.
  /// Returns null when no ghost should render — either the cursor is
  /// outside the lane, hovering inside an existing zoom, or the
  /// available gap is too small to fit a meaningful zoom.
  // Zooms are stored in SOURCE time; the timeline x-axis is edited.
  // Convert at the boundaries — ghost computation runs entirely in
  // edited time so neighbor gaps line up with what the user sees.
  Duration _sourceToEdited(Duration t) =>
      widget.clips.isEmpty ? t : sourceToEdited(widget.clips, t);
  Duration _editedToSource(Duration t) =>
      widget.clips.isEmpty ? t : editedToSource(widget.clips, t);

  ({Duration start, Duration end})? _ghostRange() {
    final hoverX = _hoverX;
    if (hoverX == null || widget.duration <= Duration.zero) return null;

    final pps = widget.pixelsPerSecond;
    final hoverTime = xToTime(hoverX.clamp(0.0, widget.contentWidth), pps);

    // If the cursor is over an existing zoom, the ghost is hidden —
    // that pill catches its own clicks anyway.
    for (final z in widget.zoomRegions) {
      final zStartE = _sourceToEdited(z.startTime);
      final zEndE = _sourceToEdited(z.endTime);
      if (hoverTime > zStartE && hoverTime < zEndE) return null;
    }

    // Find the gap [prevEnd, nextStart] surrounding hoverTime in edited
    // time. widget.duration is already edited, and we compare against
    // each zoom's edited projection so the visual gap (what the user
    // sees) drives the math, not the underlying source layout.
    var prevEnd = Duration.zero;
    var nextStart = widget.duration;
    for (final z in widget.zoomRegions) {
      final zStartE = _sourceToEdited(z.startTime);
      final zEndE = _sourceToEdited(z.endTime);
      if (zEndE <= hoverTime && zEndE > prevEnd) {
        prevEnd = zEndE;
      }
      if (zStartE >= hoverTime && zStartE < nextStart) {
        nextStart = zStartE;
      }
    }

    final gap = nextStart - prevEnd;
    if (gap < kGhostMinSpan) return null;

    final span = gap < kGhostZoomSpan ? gap : kGhostZoomSpan;

    // Mouse-x = ghost left edge; if that pushes the right edge past
    // nextStart, slide the whole ghost left until it sits flush with
    // the next zoom. Same for the prev edge.
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

  @override
  Widget build(BuildContext context) {
    final ghost = _ghostRange();

    // Clip.none so each zoom pill can extend upward into the spacing/clip
    // lane area to host its hover-revealed zoom-level badge — without that,
    // the badge falls outside the lane's hit area and its hover detection
    // breaks (cursor moving toward it triggers onExit).
    return MouseRegion(
      opaque: false,
      onHover: (e) => _setHoverX(e.localPosition.dx),
      onExit: (_) => _setHoverX(null),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Empty-area background. Tap commits a ghost zoom when one is
          // visible; otherwise falls back to seek-and-deselect.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final g = _ghostRange();
                if (g != null && widget.onZoomAdded != null) {
                  // _ghostRange returns edited bounds; the caller wants
                  // source-time so it can store the zoom in source time.
                  widget.onZoomAdded!(
                    _editedToSource(g.start),
                    _editedToSource(g.end),
                  );
                  return;
                }
                widget.onZoomSelected?.call(null);
                final x = d.localPosition.dx.clamp(0.0, widget.contentWidth);
                widget.onSeek(xToTime(x, widget.pixelsPerSecond));
              },
              child: const SizedBox.expand(),
            ),
          ),
          if (ghost != null)
            _ZoomGhost(
              start: ghost.start,
              end: ghost.end,
              pixelsPerSecond: widget.pixelsPerSecond,
            ),
          for (var i = 0; i < widget.zoomRegions.length; i++)
            _ZoomPill(
              key: ValueKey(i),
              index: i,
              zoom: widget.zoomRegions[i],
              isSelected: widget.selectedIndex == i,
              duration: widget.duration,
              pixelsPerSecond: widget.pixelsPerSecond,
              contentWidth: widget.contentWidth,
              clips: widget.clips,
              neighbors: _neighborsOf(i),
              onChanged: widget.onZoomChanged,
              onSelected: widget.onZoomSelected,
              onDeleted: widget.onZoomDeleted,
              onSeek: widget.onSeek,
            ),
        ],
      ),
    );
  }

  ({Duration? prevEnd, Duration? nextStart}) _neighborsOf(int i) {
    Duration? prev;
    Duration? next;
    final regions = widget.zoomRegions;
    for (var j = 0; j < regions.length; j++) {
      if (j == i) continue;
      final z = regions[j];
      if (z.endTime <= regions[i].startTime) {
        if (prev == null || z.endTime > prev) prev = z.endTime;
      } else if (z.startTime >= regions[i].endTime) {
        if (next == null || z.startTime < next) next = z.startTime;
      }
    }
    return (prevEnd: prev, nextStart: next);
  }
}

/// Translucent preview of a zoom that would be created on the next
/// click. Non-interactive — the lane's background tap detector commits
/// it, and the lane's MouseRegion drives hover position.
class _ZoomGhost extends StatelessWidget {
  const _ZoomGhost({
    required this.start,
    required this.end,
    required this.pixelsPerSecond,
  });

  final Duration start;
  final Duration end;
  final double pixelsPerSecond;

  @override
  Widget build(BuildContext context) {
    final pps = pixelsPerSecond;
    final left = timeToX(start, pps);
    final width = timeToX(end, pps) - left;
    // Only paint the "+" affordance when the ghost is wide enough to
    // avoid the icon spilling past the rounded edges.
    final showAddIcon = width >= 28;
    return Positioned(
      left: left,
      top: zoomBadgeAreaHeight + zoomPillInset,
      width: width,
      height: laneHeight - zoomPillInset * 2,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: zoomGhostFill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: zoomGhostStroke, width: 1),
          ),
          alignment: Alignment.center,
          child: showAddIcon
              ? const Icon(
                  Icons.add,
                  size: 18,
                  color: Colors.white,
                )
              : null,
        ),
      ),
    );
  }
}

enum _ZoomDragMode { none, body, leftEdge, rightEdge }

class _ZoomPill extends StatefulWidget {
  const _ZoomPill({
    super.key,
    required this.index,
    required this.zoom,
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
  });

  final int index;
  final ZoomRegion zoom;
  final bool isSelected;
  final Duration duration;
  final double pixelsPerSecond;
  final double contentWidth;
  final List<ClipSlice> clips;
  final ({Duration? prevEnd, Duration? nextStart}) neighbors;
  final ValueChanged<Duration> onSeek;
  final void Function(int, ZoomRegion)? onChanged;
  final ValueChanged<int?>? onSelected;
  final ValueChanged<int>? onDeleted;

  @override
  State<_ZoomPill> createState() => _ZoomPillState();
}

class _ZoomPillState extends State<_ZoomPill> {
  _ZoomDragMode _mode = _ZoomDragMode.none;
  late Duration _dragStartTime;
  late Duration _dragEndTime;
  // Cumulative dx since the drag began. We anchor the math to drag-start
  // values, not the (constantly-changing) widget.zoom, so we must track
  // the running delta ourselves — onHorizontalDragUpdate.delta.dx is
  // per-frame, not cumulative.
  double _dxAccum = 0;
  bool _hovered = false;

  // Divider drags need their own anchor + accumulator. Reading
  // widget.zoom.enterDuration each tick loses deltas when several drag
  // updates fire inside a single frame (the parent's setState batches
  // until the next rebuild) — same trap the pill body's accumulator
  // already avoids.
  Duration? _enterAnchor;
  double _enterAccum = 0;
  Duration? _exitAnchor;
  double _exitAccum = 0;

  // Zooms are stored in SOURCE time but the timeline x-axis is edited
  // time (compressed by slice playback speed + collapsed across trimmed
  // ranges). Map source → edited at the rendering and drag-clamp seams.
  Duration _sourceToEdited(Duration t) =>
      widget.clips.isEmpty ? t : sourceToEdited(widget.clips, t);
  Duration _editedToSource(Duration t) =>
      widget.clips.isEmpty ? t : editedToSource(widget.clips, t);

  double get _startX =>
      timeToX(_sourceToEdited(widget.zoom.startTime), widget.pixelsPerSecond);

  double get _endX =>
      timeToX(_sourceToEdited(widget.zoom.endTime), widget.pixelsPerSecond);

  Duration get _minStart =>
      widget.neighbors.prevEnd ?? Duration.zero;
  Duration get _maxEnd =>
      widget.neighbors.nextStart ?? widget.duration;
  Duration get _minDuration =>
      const Duration(milliseconds: minZoomDurationMs);

  void _beginMode(_ZoomDragMode mode) {
    _dxAccum = 0;
    _dragStartTime = widget.zoom.startTime;
    _dragEndTime = widget.zoom.endTime;
    _mode = mode;
    widget.onSelected?.call(widget.index);
  }

  void _endDrag() {
    setState(() {
      _mode = _ZoomDragMode.none;
      _dxAccum = 0;
    });
  }

  void _update(double dxDelta) {
    if (widget.onChanged == null) return;
    _dxAccum += dxDelta;
    final scale = widget.duration.inMicroseconds / widget.contentWidth;
    final deltaUs = (_dxAccum * scale).round();
    final delta = Duration(microseconds: deltaUs);

    // Drags happen in edited time (1px = 1/pps edited seconds), so we
    // operate on the EDITED projections of the anchored source-time
    // start/end, then map back to source time at commit. Neighbor and
    // duration clamps also live in edited space so the visual gap to
    // neighbors stays constant on the timeline.
    final editedDragStart = _sourceToEdited(_dragStartTime);
    final editedDragEnd = _sourceToEdited(_dragEndTime);
    final editedMinStart = _sourceToEdited(_minStart);
    final editedMaxEnd = _sourceToEdited(_maxEnd);

    var editedNextStart = editedDragStart;
    var editedNextEnd = editedDragEnd;

    switch (_mode) {
      case _ZoomDragMode.body:
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
        break;
      case _ZoomDragMode.leftEdge:
        editedNextStart = editedDragStart + delta;
        if (editedNextStart < editedMinStart) editedNextStart = editedMinStart;
        if (editedNextEnd - editedNextStart < _minDuration) {
          editedNextStart = editedNextEnd - _minDuration;
        }
        break;
      case _ZoomDragMode.rightEdge:
        editedNextEnd = editedDragEnd + delta;
        if (editedNextEnd > editedMaxEnd) editedNextEnd = editedMaxEnd;
        if (editedNextEnd - editedNextStart < _minDuration) {
          editedNextEnd = editedNextStart + _minDuration;
        }
        break;
      case _ZoomDragMode.none:
        return;
    }

    var nextStart = _editedToSource(editedNextStart);
    var nextEnd = _editedToSource(editedNextEnd);

    final newDuration = nextEnd - nextStart;
    // Scale the enter / exit ramps if the new region is shorter than
    // the sum of their stored durations — otherwise the dividers visually
    // cross and the model stores impossible state. We scale proportionally
    // so the enter:exit ratio is preserved.
    Duration newEnter = widget.zoom.enterDuration;
    Duration newExit = widget.zoom.exitDuration;
    final ramps = newEnter + newExit;
    if (ramps > newDuration && ramps > Duration.zero) {
      final factor =
          newDuration.inMicroseconds / ramps.inMicroseconds;
      final scaledEnterUs =
          (newEnter.inMicroseconds * factor).round();
      newEnter = Duration(microseconds: scaledEnterUs);
      newExit = newDuration - newEnter;
    }

    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        startTime: nextStart,
        duration: newDuration,
        enterDuration: newEnter,
        exitDuration: newExit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final left = _startX;
    final pillWidth =
        (_endX - _startX).clamp(handleHitWidth * 2, double.infinity);
    final pillBodyHeight = laneHeight - zoomPillInset * 2;
    final fillTop = widget.isSelected ? zoomFillSelected : zoomFillTop;
    final fill = widget.isSelected ? zoomFillSelected : zoomFill;
    final stroke = widget.isSelected ? Colors.white : zoomStroke;

    final regionUs = widget.zoom.duration.inMicroseconds;
    final pxPerRegionUs = regionUs == 0 ? 0.0 : pillWidth / regionUs;
    final enterPx = widget.zoom.enterDuration.inMicroseconds * pxPerRegionUs;
    final exitPx =
        pillWidth - widget.zoom.exitDuration.inMicroseconds * pxPerRegionUs;

    // The zoom lane is sized to (pillBodyHeight + badgeArea + 2*inset). The
    // outer MouseRegion only tracks `_hovered` for show-on-hover affordances
    // (edge handles, ramp dividers, badge). Cursor is set per-zone by the
    // inner MouseRegions: grab on the body, resizeLeftRight on the edges.
    return Positioned(
      left: left,
      top: zoomPillInset,
      width: pillWidth,
      height: pillBodyHeight + zoomBadgeAreaHeight,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Pill body — translate-on-drag, select+seek on tap.
            Positioned(
              left: 0,
              right: 0,
              top: zoomBadgeAreaHeight,
              height: pillBodyHeight,
              child: MouseRegion(
                cursor: _mode == _ZoomDragMode.body
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    // Select-only; don't seek the playhead. The user
                    // wants to inspect/edit the region's properties
                    // from wherever they are in the clip, not jump to
                    // its start.
                    widget.onSelected?.call(widget.index);
                  },
                  onHorizontalDragStart: (_) =>
                      _beginMode(_ZoomDragMode.body),
                  onHorizontalDragUpdate: (d) => _update(d.delta.dx),
                  onHorizontalDragEnd: (_) => _endDrag(),
                  onHorizontalDragCancel: _endDrag,
                  child: CustomPaint(
                    painter: _ZoomPillPainter(
                      fillTop: fillTop,
                      fill: fill,
                      stroke: stroke,
                      zoomLevel: widget.zoom.zoomLevel,
                      enterPx: enterPx,
                      exitPx: exitPx,
                      showInternalGuides: _hovered,
                      isSelected: widget.isSelected,
                    ),
                  ),
                ),
              ),
            ),
            // Left resize handle — its own MouseRegion so the cursor flips
            // to resizeLeftRight on hover (not just during a drag).
            Positioned(
              left: 0,
              top: zoomBadgeAreaHeight,
              width: handleHitWidth,
              height: pillBodyHeight,
              child: _PillEdgeHandle(
                alignment: Alignment.centerLeft,
                showHandle: _hovered,
                onDragStart: () => _beginMode(_ZoomDragMode.leftEdge),
                onDragUpdate: _update,
                onDragEnd: _endDrag,
                onTap: () => widget.onSelected?.call(widget.index),
              ),
            ),
            // Right resize handle.
            Positioned(
              right: 0,
              top: zoomBadgeAreaHeight,
              width: handleHitWidth,
              height: pillBodyHeight,
              child: _PillEdgeHandle(
                alignment: Alignment.centerRight,
                showHandle: _hovered,
                onDragStart: () => _beginMode(_ZoomDragMode.rightEdge),
                onDragUpdate: _update,
                onDragEnd: _endDrag,
                onTap: () => widget.onSelected?.call(widget.index),
              ),
            ),
            if (_hovered && pillWidth > handleHitWidth * 4) ...[
              _RampDivider(
                centerX: enterPx,
                top: zoomBadgeAreaHeight,
                height: pillBodyHeight,
                onDragStart: _beginEnterDrag,
                onDelta: _onEnterDividerDrag,
                onDragEnd: _endEnterDrag,
                tooltip: 'Enter ${widget.zoom.enterDuration.inMilliseconds}ms',
              ),
              _RampDivider(
                centerX: exitPx,
                top: zoomBadgeAreaHeight,
                height: pillBodyHeight,
                onDragStart: _beginExitDrag,
                onDelta: _onExitDividerDrag,
                onDragEnd: _endExitDrag,
                tooltip: 'Exit ${widget.zoom.exitDuration.inMilliseconds}ms',
              ),
            ],
            if (_hovered)
              Positioned(
                left: pillWidth / 2 - 38,
                top: 0,
                child: _ZoomLevelBadge(
                  level: widget.zoom.zoomLevel,
                  onIncrement: () => _stepZoomLevel(0.1),
                  onDecrement: () => _stepZoomLevel(-0.1),
                ),
              ),
            if (_hovered && widget.onDeleted != null)
              Positioned(
                top: zoomBadgeAreaHeight - 6,
                right: -6,
                child: _ZoomDeleteButton(
                  onPressed: () => widget.onDeleted!(widget.index),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _beginEnterDrag() {
    _enterAnchor = widget.zoom.enterDuration;
    _enterAccum = 0;
  }

  void _onEnterDividerDrag(double dx) {
    if (widget.onChanged == null || _enterAnchor == null) return;
    _enterAccum += dx;
    final usPerPx =
        widget.duration.inMicroseconds / widget.contentWidth;
    final deltaUs = (_enterAccum * usPerPx).round();
    final maxEnterUs = widget.zoom.duration.inMicroseconds -
        widget.zoom.exitDuration.inMicroseconds;
    final newEnterUs = (_enterAnchor!.inMicroseconds + deltaUs)
        .clamp(0, maxEnterUs);
    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        enterDuration: Duration(microseconds: newEnterUs),
      ),
    );
  }

  void _endEnterDrag() {
    _enterAnchor = null;
    _enterAccum = 0;
  }

  void _beginExitDrag() {
    _exitAnchor = widget.zoom.exitDuration;
    _exitAccum = 0;
  }

  void _onExitDividerDrag(double dx) {
    if (widget.onChanged == null || _exitAnchor == null) return;
    _exitAccum += dx;
    final usPerPx =
        widget.duration.inMicroseconds / widget.contentWidth;
    // Dragging the exit divider rightward shortens the exit ramp.
    final deltaUs = (-_exitAccum * usPerPx).round();
    final maxExitUs = widget.zoom.duration.inMicroseconds -
        widget.zoom.enterDuration.inMicroseconds;
    final newExitUs =
        (_exitAnchor!.inMicroseconds + deltaUs).clamp(0, maxExitUs);
    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        exitDuration: Duration(microseconds: newExitUs),
      ),
    );
  }

  void _endExitDrag() {
    _exitAnchor = null;
    _exitAccum = 0;
  }

  void _stepZoomLevel(double delta) {
    if (widget.onChanged == null) return;
    final next = (widget.zoom.zoomLevel + delta).clamp(1.0, 5.0);
    final rounded = (next * 10).round() / 10.0;
    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(zoomLevel: rounded),
    );
  }

}

/// Resize handle anchored to one edge of a zoom pill (or any draggable
/// timeline bar). The hit zone is fixed-width but the visible bar lives
/// inside it via [Align] + [Padding] — invisible until the parent reports
/// `showHandle: true`, then fades in dim and brightens on direct hover.
/// Mirrors [_RampDivider]'s visual language for consistency.
class _PillEdgeHandle extends StatefulWidget {
  const _PillEdgeHandle({
    required this.alignment,
    required this.showHandle,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  /// `centerLeft` for the left edge, `centerRight` for the right,
  /// `center` for a freestanding handle.
  final Alignment alignment;
  /// Whether the parent (e.g. the zoom pill) is currently hovered.
  /// When false the bar is fully transparent so it doesn't clutter
  /// the timeline; the MouseRegion still hit-tests so the cursor flips
  /// to resizeLeftRight the moment the user enters the zone.
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => widget.onTap(),
        onHorizontalDragStart: (_) {
          setState(() => _dragging = true);
          widget.onDragStart();
        },
        onHorizontalDragUpdate: (d) => widget.onDragUpdate(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 8,
          ),
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
                          color: Color(0x806C63FF),
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

/// Vertical drag-handle inside a zoom pill marking the boundary between
/// ramp and hold (enter or exit). Subtle when not directly hovered;
/// expands into a clear grip when the cursor is over it.
class _RampDivider extends StatefulWidget {
  const _RampDivider({
    required this.centerX,
    required this.top,
    required this.height,
    required this.onDragStart,
    required this.onDelta,
    required this.onDragEnd,
    required this.tooltip,
  });

  final double centerX;
  final double top;
  final double height;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDelta;
  final VoidCallback onDragEnd;
  final String tooltip;

  @override
  State<_RampDivider> createState() => _RampDividerState();
}

class _RampDividerState extends State<_RampDivider> {
  bool _hover = false;
  bool _dragging = false;
  static const double _hitWidth = 14;
  static const double _verticalPadding = 6;

  @override
  Widget build(BuildContext context) {
    final emphasized = _hover || _dragging;

    return Positioned(
      left: widget.centerX - _hitWidth / 2,
      top: widget.top,
      width: _hitWidth,
      height: widget.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Tooltip(
          message: widget.tooltip,
          waitDuration: const Duration(milliseconds: 350),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) {
              setState(() => _dragging = true);
              widget.onDragStart();
            },
            onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              widget.onDragEnd();
            },
            onHorizontalDragCancel: () {
              setState(() => _dragging = false);
              widget.onDragEnd();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: emphasized ? 4 : 3,
                  decoration: BoxDecoration(
                    color: emphasized
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.30),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: emphasized
                        ? const [
                            BoxShadow(
                              color: Color(0xCC000000),
                              blurRadius: 6,
                              offset: Offset(0, 1),
                            ),
                            BoxShadow(
                              color: Color(0x806C63FF),
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
        ),
      ),
    );
  }
}

/// Floating zoom-level pill above the zoom region, with chevron buttons
/// to step the zoom level by 0.1× when hovered. Each chevron has its
/// own hover state so it visibly highlights when targetable.
class _ZoomLevelBadge extends StatelessWidget {
  const _ZoomLevelBadge({
    required this.level,
    required this.onIncrement,
    required this.onDecrement,
  });

  final double level;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChevronButton(icon: Icons.remove, onPressed: onDecrement),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            // Animate the displayed value so a 1.6× → 1.7× change eases
            // through 1.61, 1.62, … instead of snapping.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: level),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => Text(
                '${value.toStringAsFixed(1)}×',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _ChevronButton(icon: Icons.add, onPressed: onIncrement),
        ],
      ),
    );
  }
}

class _ChevronButton extends StatefulWidget {
  const _ChevronButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_ChevronButton> createState() => _ChevronButtonState();
}

class _ChevronButtonState extends State<_ChevronButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? Colors.white24 : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(widget.icon, size: 13, color: Colors.white),
        ),
      ),
    );
  }
}

class _ZoomDeleteButton extends StatelessWidget {
  const _ZoomDeleteButton({required this.onPressed});

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

class _ZoomPillPainter extends CustomPainter {
  _ZoomPillPainter({
    required this.fillTop,
    required this.fill,
    required this.stroke,
    required this.zoomLevel,
    required this.enterPx,
    required this.exitPx,
    required this.showInternalGuides,
    required this.isSelected,
  });

  final Color fillTop;
  final Color fill;
  final Color stroke;
  final double zoomLevel;
  final double enterPx;
  final double exitPx;
  final bool showInternalGuides;
  final bool isSelected;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));

    // Three visually distinct phases — enter ramp / hold / exit ramp.
    // The hold uses the full saturated fill; enter and exit are clearly
    // de-saturated and faded on the outer edge so the user can read the
    // shape of the zoom at a glance. We clip to the rounded rect so the
    // segment seams align with the pill's outline.
    canvas.save();
    canvas.clipRRect(rrect);

    final clampedEnter = enterPx.clamp(0.0, size.width);
    final clampedExit = exitPx.clamp(clampedEnter, size.width);
    final holdColor = fill;
    // Enter ramp: horizontal gradient from the pill edge (low-alpha
    // de-saturated) into full saturated fill at the divider.
    if (clampedEnter > 0) {
      final enterRect = Rect.fromLTWH(0, 0, clampedEnter, size.height);
      canvas.drawRect(
        enterRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              holdColor.withValues(alpha: 0.45),
              holdColor,
            ],
          ).createShader(enterRect),
      );
    }
    // Hold: the bright, saturated middle.
    if (clampedExit > clampedEnter) {
      final holdRect = Rect.fromLTWH(
        clampedEnter, 0, clampedExit - clampedEnter, size.height);
      canvas.drawRect(
        holdRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [fillTop, holdColor],
          ).createShader(holdRect),
      );
    }
    // Exit ramp: mirror of enter — solid to faded on the right edge.
    if (clampedExit < size.width) {
      final exitRect = Rect.fromLTWH(
        clampedExit, 0, size.width - clampedExit, size.height);
      canvas.drawRect(
        exitRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              holdColor,
              holdColor.withValues(alpha: 0.45),
            ],
          ).createShader(exitRect),
      );
    }

    canvas.restore();

    // Border on top of all segments.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 1.5 : 1
        ..color = stroke,
    );

    // Faint enter/exit ramp dividers, only while the pill is hovered.
    // The actual draggable handles are interactive Positioned widgets above
    // this layer; this just hints at where they live.
    if (showInternalGuides) {
      final guidePaint = Paint()..color = const Color(0x55FFFFFF);
      for (final cx in [enterPx, exitPx]) {
        if (cx > 6 && cx < size.width - 6) {
          canvas.drawLine(
            Offset(cx, size.height * 0.16),
            Offset(cx, size.height * 0.84),
            guidePaint..strokeWidth = 1,
          );
        }
      }
    }

    // Title + subtitle (only when the pill is wide enough to fit it).
    if (size.width < 60) return;
    final main = TextPainter(
      text: const TextSpan(
        text: 'Zoom',
        style: TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    final sub = TextPainter(
      text: TextSpan(
        text: '${zoomLevel.toStringAsFixed(zoomLevel == zoomLevel.roundToDouble() ? 0 : 1)}×  ·  Auto',
        style: const TextStyle(
          color: Color(0xCCFFFFFF),
          fontSize: 10,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    final totalH = main.height + sub.height + 1;
    final cy = size.height / 2 - totalH / 2;
    main.paint(canvas, Offset(size.width / 2 - main.width / 2, cy));
    sub.paint(canvas,
        Offset(size.width / 2 - sub.width / 2, cy + main.height + 1));
  }

  @override
  bool shouldRepaint(_ZoomPillPainter old) =>
      old.fillTop != fillTop ||
      old.fill != fill ||
      old.stroke != stroke ||
      old.zoomLevel != zoomLevel ||
      old.enterPx != enterPx ||
      old.exitPx != exitPx ||
      old.showInternalGuides != showInternalGuides ||
      old.isSelected != isSelected;
}
