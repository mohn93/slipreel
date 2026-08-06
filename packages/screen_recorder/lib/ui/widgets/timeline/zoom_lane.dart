import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Pointer kinds that count as a real "grab and drag" gesture on the
/// zoom pill and its edge handles. Mouse, touch, stylus — i.e. things
/// where the user explicitly initiated a press before moving. Trackpad
/// pan is EXCLUDED on purpose: a two-finger scroll over the pill
/// should propagate to the timeline's SingleChildScrollView and pan
/// the view, not slide the pill around. (The drag recognizers used to
/// accept trackpad pan-zoom by default, which is what made the pill
/// "jump out from under" any attempt to scroll.)
const Set<PointerDeviceKind> _kPillDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// Resolves the enter/exit ramps for a zoom region being resized.
///
/// Resizing or translating a region does NOT recompute its ramps — they
/// pass through from where they were at drag start (issue #4). Enter/exit
/// durations change only when the user edits them explicitly in the zoom
/// inspector, so the animation feel never drifts just because a region was
/// stretched or shrunk.
///
/// The one exception is the defensive clamp: if the region is shrunk
/// shorter than enter+exit, the ramps are proportionally compressed so the
/// model never stores an impossible (ramps > duration) state.
@visibleForTesting
({Duration enter, Duration exit}) resolveResizeRamps({
  required Duration dragStartEnter,
  required Duration dragStartExit,
  required Duration newDuration,
}) {
  var enter = dragStartEnter;
  var exit = dragStartExit;
  final ramps = enter + exit;
  if (ramps > newDuration && ramps > Duration.zero) {
    final factor = newDuration.inMicroseconds / ramps.inMicroseconds;
    enter = Duration(microseconds: (enter.inMicroseconds * factor).round());
    exit = newDuration - enter;
  }
  return (enter: enter, exit: exit);
}

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
    this.onBarPointerDown,
    this.trimDragging = false,
    this.animateLayout = true,
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

  /// Fires on pointer-down anywhere on a zoom pill (body, handles, delete).
  /// The timeline uses it to suppress its tap-seek for that gesture so a
  /// pill press selects/drags WITHOUT the tap-seek committing a seek that
  /// would immediately deselect the just-selected pill.
  final VoidCallback? onBarPointerDown;

  /// True while ANY slice's trim handle is being dragged anywhere in
  /// the timeline. Drives the zoom-pill position tween's duration —
  /// snap to 0 during a drag so the pill tracks the live (possibly
  /// rapidly shifting) layout in real time, then animate the
  /// post-drag settle with the rest of the timeline.
  final bool trimDragging;

  /// Whether zoom-pill position/width changes should ease to their new
  /// geometry. Pinch zoom disables this so pills stay pinned to the
  /// same source-time anchor instead of chasing a 220 ms tween.
  final bool animateLayout;

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

  ({Duration start, Duration end})? _ghostRange() => _ghostRangeForX(_hoverX);

  ({Duration start, Duration end})? _ghostRangeForX(double? x) {
    if (x == null || widget.duration <= Duration.zero) return null;

    final pps = widget.pixelsPerSecond;
    final hoverTime = xToTime(x.clamp(0.0, widget.contentWidth), pps);

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
                final x = d.localPosition.dx.clamp(0.0, widget.contentWidth);
                final g = _ghostRangeForX(x);
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
              },
              child: const SizedBox.expand(),
            ),
          ),
          // Empty-state hint — only when there are no zoom regions
          // yet. Stays IgnorePointer so the underlying empty-area
          // GestureDetector still routes clicks/drags to the
          // add-zoom path. Reacts to lane hover via the shared
          // [_hoverX] state — no second MouseRegion needed.
          if (widget.zoomRegions.isEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _EmptyZoomLaneHint(hovered: _hoverX != null),
                ),
              ),
            ),
          if (ghost != null)
            _ZoomGhost(
              start: ghost.start,
              end: ghost.end,
              pixelsPerSecond: widget.pixelsPerSecond,
            ),
          // Keyed by the region's stable identity, NOT the list index: with
          // index keys, deleting region k re-bound every later pill element
          // to its right neighbour's data and each pill's AnimatedPositioned
          // tweened from the old geometry — the survivors visibly slid
          // across the lane on every delete.
          for (var i = 0; i < widget.zoomRegions.length; i++)
            _ZoomPill(
              key: ValueKey(widget.zoomRegions[i].id),
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
              onBarPointerDown: widget.onBarPointerDown,
              trimDragging: widget.trimDragging,
              animateLayout: widget.animateLayout,
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
              ? const Icon(Icons.add, size: 18, color: Colors.white)
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
    this.onBarPointerDown,
    this.trimDragging = false,
    this.animateLayout = true,
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
  final VoidCallback? onBarPointerDown;
  final bool trimDragging;
  final bool animateLayout;

  @override
  State<_ZoomPill> createState() => _ZoomPillState();
}

class _ZoomPillState extends State<_ZoomPill> {
  _ZoomDragMode _mode = _ZoomDragMode.none;
  late Duration _dragStartTime;
  late Duration _dragEndTime;
  // Enter/exit at drag start. The proportional-scaling rule reads
  // these (not widget.zoom.*) every update so the ramps stay locked
  // to their drag-start fraction-of-pill-width across the whole
  // gesture, even though onChanged pushes new enter/exit each tick.
  late Duration _dragStartEnter;
  late Duration _dragStartExit;
  // Cumulative dx since the drag began. We anchor the math to drag-start
  // values, not the (constantly-changing) widget.zoom, so we must track
  // the running delta ourselves — onHorizontalDragUpdate.delta.dx is
  // per-frame, not cumulative.
  double _dxAccum = 0;
  bool _hovered = false;

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

  Duration get _minDuration => const Duration(milliseconds: minZoomDurationMs);

  void _beginMode(_ZoomDragMode mode) {
    _dxAccum = 0;
    _dragStartTime = widget.zoom.startTime;
    _dragEndTime = widget.zoom.endTime;
    _dragStartEnter = widget.zoom.enterDuration;
    _dragStartExit = widget.zoom.exitDuration;
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
    // Clamp bounds in EDITED time. Neighbor bounds are source time (mapped);
    // the open-ended fallbacks are the timeline extremes, already edited time
    // and NOT re-mapped — see editedRegionDragBounds (M2).
    final bounds = editedRegionDragBounds(
      clips: widget.clips,
      prevEndSource: widget.neighbors.prevEnd,
      nextStartSource: widget.neighbors.nextStart,
      timelineDuration: widget.duration,
    );
    final editedMinStart = bounds.min;
    final editedMaxEnd = bounds.max;

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
    // Resizing/translating a region passes the ramps through unchanged;
    // they only ever shrink under the defensive clamp when the region is
    // dragged shorter than enter+exit. See resolveResizeRamps (#4).
    final ramps = resolveResizeRamps(
      dragStartEnter: _dragStartEnter,
      dragStartExit: _dragStartExit,
      newDuration: newDuration,
    );

    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        startTime: nextStart,
        duration: newDuration,
        enterDuration: ramps.enter,
        exitDuration: ramps.exit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final left = _startX;
    // A very short region is floored to a grabbable width, but the floor must
    // never push the pill past the next region's left edge. Pills are added to
    // the lane's Stack in ascending order, so an inflated pill paints UNDER
    // its neighbour and the neighbour's opaque gesture detector swallows this
    // pill's right-edge resize handle and delete button (both positioned off
    // the inflated box). Overlap resolution makes regions abut exactly, so
    // once a second maps to under 32px — roughly 30s of recording at 1x —
    // that inflation would be the norm, not an edge case. Reuses the same
    // neighbour info the drag clamp reads.
    final naturalWidth = _endX - _startX;
    final nextStart = widget.neighbors.nextStart;
    final gapToNext = nextStart == null
        ? double.infinity
        : (timeToX(_sourceToEdited(nextStart), widget.pixelsPerSecond) - left)
              .clamp(0.0, double.infinity);
    final widthFloor = gapToNext < handleHitWidth * 2
        ? gapToNext
        : handleHitWidth * 2;
    final pillWidth = naturalWidth > widthFloor ? naturalWidth : widthFloor;
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
    //
    // Tween left/width over 220 ms easeOutCubic so the pill follows
    // SliceBar's body width animation in lockstep during non-drag
    // layout shifts (cut-marker tap restore, mergeSeam, setSliceSpeed).
    // During a live trim drag or pinch zoom the underlying layout
    // changes every frame; snap with Duration.zero so the pill stays
    // glued to its source-time anchor in real time rather than
    // dragging behind. Pill state (drag mode, hover) is unaffected —
    // AnimatedPositioned only animates the outer Stack-slot geometry.
    return AnimatedPositioned(
      duration: widget.trimDragging || !widget.animateLayout
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: left,
      top: zoomPillInset,
      width: pillWidth,
      height: pillBodyHeight + zoomBadgeAreaHeight,
      // Raw pointer-down hook (fires deepest-first, before the timeline's
      // tap-seek Listener) so a press anywhere on the pill suppresses the
      // tap-seek for this gesture — selecting/dragging a pill must not commit
      // a seek that immediately deselects it.
      child: Listener(
        onPointerDown: (_) => widget.onBarPointerDown?.call(),
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
                // RawGestureDetector (not GestureDetector) so we can
                // restrict the horizontal-drag recognizer to mouse /
                // touch / stylus — trackpad pan flows through to the
                // timeline scroll view instead of dragging the pill.
                child: RawGestureDetector(
                  key: ValueKey('zoom-pill-body-${widget.index}'),
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
                              ..onStart = ((_) =>
                                  _beginMode(_ZoomDragMode.body))
                              ..onUpdate = ((d) => _update(d.delta.dx))
                              ..onEnd = ((_) => _endDrag())
                              ..onCancel = _endDrag;
                          },
                        ),
                  },
                  child: CustomPaint(
                    painter: _ZoomPillPainter(
                      fillTop: fillTop,
                      fill: fill,
                      stroke: stroke,
                      zoomLevel: widget.zoom.zoomLevel,
                      enterPx: enterPx,
                      exitPx: exitPx,
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
            // Delete affordance sits at the pill's top-right corner,
            // poking out by 6 px so it stays clickable without
            // overlapping the pill's body or the +/− label inside it.
            // (The floating zoom-level +/− badge that used to live
            // above the pill is gone — the level is now shown inline
            // by [_ZoomPillPainter]; see the spec change in this
            // commit.)
            if (_hovered && widget.onDeleted != null)
              Positioned(
                top: -6,
                right: -6,
                child: _ZoomDeleteButton(
                  onPressed: () => widget.onDeleted!(widget.index),
                ),
              ),
          ],
          ),
        ),
      ),
    );
  }
}

/// Resize handle anchored to one edge of a zoom pill (or any draggable
/// timeline bar). The hit zone is fixed-width but the visible bar lives
/// inside it via [Align] + [Padding] — invisible until the parent reports
/// `showHandle: true`, then fades in dim and brightens on direct hover.
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
      // RawGestureDetector so the resize drag ignores trackpad pan —
      // a two-finger scroll over a handle pans the timeline rather
      // than secretly resizing the pill.
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
    required this.isSelected,
  });

  final Color fillTop;
  final Color fill;
  final Color stroke;
  final double zoomLevel;
  final double enterPx;
  final double exitPx;
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
            colors: [holdColor.withValues(alpha: 0.45), holdColor],
          ).createShader(enterRect),
      );
    }
    // Hold: the bright, saturated middle.
    if (clampedExit > clampedEnter) {
      final holdRect = Rect.fromLTWH(
        clampedEnter,
        0,
        clampedExit - clampedEnter,
        size.height,
      );
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
        clampedExit,
        0,
        size.width - clampedExit,
        size.height,
      );
      canvas.drawRect(
        exitRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [holdColor, holdColor.withValues(alpha: 0.45)],
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

    // (Ramp divider draggable handles + their faint hover guides
    // were removed — enter/exit now scale proportionally with the
    // pill width, edited via the debug-only side-pane sliders. The
    // gradient banding inside the pill is enough to convey the ramp
    // shape; explicit dividers added clutter without an action.)

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
        text:
            '${zoomLevel.toStringAsFixed(zoomLevel == zoomLevel.roundToDouble() ? 0 : 1)}×  ·  Auto',
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
    sub.paint(
      canvas,
      Offset(size.width / 2 - sub.width / 2, cy + main.height + 1),
    );
  }

  @override
  bool shouldRepaint(_ZoomPillPainter old) =>
      old.fillTop != fillTop ||
      old.fill != fill ||
      old.stroke != stroke ||
      old.zoomLevel != zoomLevel ||
      old.enterPx != enterPx ||
      old.exitPx != exitPx ||
      old.isSelected != isSelected;
}

/// Empty-state hint shown in the zoom lane until the project has its
/// first zoom region. Animates a soft tint + border lift when the
/// cursor enters the lane so it feels alive rather than static
/// chrome. `hovered` is driven by the parent's shared hover state so
/// the hint never needs its own MouseRegion (which would have to
/// fight the lane's existing add-on-click GestureDetector).
class _EmptyZoomLaneHint extends StatelessWidget {
  const _EmptyZoomLaneHint({required this.hovered});

  final bool hovered;

  static const Duration _anim = Duration(milliseconds: 220);
  static const Curve _curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    final restColor = const Color(0xFFFFFFFF).withValues(alpha: 0.03);
    final hoverColor = const Color(0xFF7C6BFF).withValues(alpha: 0.08);
    final restBorder = const Color(0xFFFFFFFF).withValues(alpha: 0.08);
    final hoverBorder = const Color(0xFF7C6BFF).withValues(alpha: 0.45);
    final restText = const Color(0xFFAAAAB5).withValues(alpha: 0.65);
    final hoverText = const Color(0xFFE6E1FF);

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
              Icons.zoom_in_rounded,
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
            child: const Text('Click or drag to add zoom'),
          ),
        ],
      ),
    );
  }
}
