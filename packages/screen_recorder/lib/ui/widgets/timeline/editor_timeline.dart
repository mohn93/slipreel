import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:screen_recorder/onboarding/tip_anchor.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/ui/widgets/timeline/clip_lane.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker_strip.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_overlay.dart';
import 'package:screen_recorder/ui/widgets/timeline/playhead_painter.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';
import 'package:screen_recorder/ui/widgets/timeline/time_ruler.dart';
import 'package:screen_recorder/ui/widgets/timeline/snap_flash_overlay.dart';
import 'package:screen_recorder/ui/widgets/timeline/zoom_lane.dart';

/// Computes the hover-scrub progress fraction (0..1 of total content)
/// from the raw inputs that [_updateHover] has available.
///
///   viewportX   — cursor x relative to the viewport (MouseRegion local.dx)
///   scrollOffset — current [ScrollController.offset]
///   viewportWidth — LayoutBuilder width passed to _updateHover
///   scale       — widget.timelineScale
double _progressFromHover(
  double viewportX,
  double scrollOffset,
  double viewportWidth,
  double scale,
) {
  final content = contentWidth(viewportWidth, scale);
  if (content <= 0) return 0.0;
  return ((viewportX + scrollOffset) / content).clamp(0.0, 1.0);
}

// Test-only re-exports (private helpers in lib code can't be reached
// from `test/`; these proxies keep the helpers private to lib but
// addressable from unit tests).
@visibleForTesting
double pixelsPerSecondForTest(double v, Duration t, double s) =>
    pixelsPerSecond(v, t, s);
@visibleForTesting
double timeToXForTest(Duration t, double pps) => timeToX(t, pps);
@visibleForTesting
Duration xToTimeForTest(double x, double pps) => xToTime(x, pps);
@visibleForTesting
double contentWidthForTest(double v, double s) => contentWidth(v, s);
@visibleForTesting
double progressFromHoverForTest(
  double viewportX,
  double scrollOffset,
  double viewportWidth,
  double scale,
) =>
    _progressFromHover(viewportX, scrollOffset, viewportWidth, scale);

/// Stacked editor timeline: time ruler on top, clip lane in the middle,
/// optional zoom lane on the bottom. A single playhead line runs across all
/// rows. Designed to be redrawn at vsync (caller passes a smoothed
/// `position`) so the playhead glides instead of stepping.
class EditorTimeline extends ConsumerStatefulWidget {
  const EditorTimeline({
    super.key,
    required this.duration,
    required this.position,
    required this.onSeek,
    this.zoomRegions = const [],
    this.selectedZoomIndex,
    this.onZoomChanged,
    this.onZoomSelected,
    this.onZoomDeleted,
    this.onZoomAdded,
    this.clips = const [],
    this.selectedSliceIndex,
    this.onSliceSelected,
    this.cursorXListenable,
    this.onSliceTrimStartChanged,
    this.onSliceTrimEndChanged,
    this.onClearSeamTrims,
    this.onMergeSeam,
    this.cutModeActive = false,
    this.onCutModeChanged,
    this.playheadFlashOn = false,
    this.playbackSpeedLabel = '1x',
    this.isPlaying = false,
    this.onHoverSeek,
    this.onHoverEnd,
    this.timelineScale = 1.0,
    this.pendingScaleAnchor,
    this.onAnchorConsumed,
    this.onPinchScale,
    this.cursorClickTimes = const <Duration>[],
    this.onSnapped,
    this.snapFlashTarget,
  });

  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  final List<ZoomRegion> zoomRegions;
  final int? selectedZoomIndex;
  final void Function(int index, ZoomRegion next)? onZoomChanged;
  final ValueChanged<int?>? onZoomSelected;
  final ValueChanged<int>? onZoomDeleted;
  /// Click-to-add: fires with `(start, end)` for the ghost the user
  /// just committed by tapping in the empty area of the zoom lane.
  final void Function(Duration start, Duration end)? onZoomAdded;

  /// The project's clip slices. Rendered in edited-time order by the
  /// embedded [ClipLane] — trimmed-away source regions disappear.
  final List<ClipSlice> clips;

  /// Index of the slice the user has tapped (null = none). Drives the
  /// per-slice selection highlight; the parent uses this to swap the
  /// inspector into the slice editor.
  final int? selectedSliceIndex;

  /// Bubbles up from [ClipLane] when the user taps a slice. Null
  /// payload means "deselect" — same callback handles both directions.
  final ValueChanged<int?>? onSliceSelected;

  /// Drives the magnetic-pull transform on each [SliceBar]. Task 10
  /// wires this to the real cut-mode cursor; everywhere else a null
  /// notifier is fine (no pull).
  final ValueListenable<double?>? cursorXListenable;

  /// Per-slice trim-handle drag callbacks. Routed by the parent to
  /// `EditorProjectController.setSliceTrimStart/setSliceTrimEnd`.
  final void Function(int sliceIndex, Duration trimStart)? onSliceTrimStartChanged;
  final void Function(int sliceIndex, Duration trimEnd)? onSliceTrimEndChanged;

  /// Fired by [CutMarkerStrip] when the user taps a seam that has
  /// trimmed-away content — clears both trim handles so the full source
  /// footage is restored at that seam.
  final ValueChanged<int>? onClearSeamTrims;

  /// Fired by [CutMarkerStrip] when the user taps a clean seam (no hidden
  /// content) — merges the two adjacent slices into one.
  final ValueChanged<int>? onMergeSeam;

  /// True while the scissors tool is engaged. When on, the timeline
  /// renders a [CutOverlay] above the clip lane and routes its
  /// cursor-x notifier into [ClipLane] so SliceBars get magnetic pull.
  final bool cutModeActive;

  /// Bubbled by the overlay to the parent on Esc / successful cut.
  /// Parent flips its own `_cutModeActive` state field.
  final ValueChanged<bool>? onCutModeChanged;

  /// Drives a brief 120ms accent-color flash on the playhead pill.
  /// Parent flips this true → false after the timer to signal a
  /// rejected Cmd+K cut.
  final bool playheadFlashOn;
  final String playbackSpeedLabel;
  final bool isPlaying;
  // Live preview seek while the cursor hovers the timeline (paused only).
  // Wired separately from `onSeek` so the caller can skip side-effects
  // (zoom-marker selection, history pushes) for the high-frequency hover
  // stream.
  final ValueChanged<Duration>? onHoverSeek;
  // Fired once when the cursor leaves the timeline so the caller can
  // restore the playback position to where it was before hover started.
  final VoidCallback? onHoverEnd;

  /// Horizontal zoom: 1.0 = fit-to-width, up to 8.0 = 8× wider.
  /// Threaded down from EditorProjectState so the widget stays
  /// Riverpod-free.
  final double timelineScale;

  /// One-shot anchor hint. When set + when [timelineScale] changes,
  /// the widget preserves this timestamp's on-screen x-position by
  /// adjusting its scroll offset. Cleared via [onAnchorConsumed].
  final Duration? pendingScaleAnchor;

  /// Invoked by the widget after consuming a non-null
  /// [pendingScaleAnchor]. The parent should reset the anchor via
  /// `EditorProjectController.clearPendingScaleAnchor()`.
  final VoidCallback? onAnchorConsumed;

  /// Fires on each trackpad-pinch update over the timeline lanes.
  /// Args: `(newScale, anchorTime)`. The caller routes through
  /// `EditorProjectController.setTimelineScale(newScale, anchorTime:
  /// anchorTime)`. Single-finger drags are filtered out.
  final void Function(double scale, Duration anchorTime)? onPinchScale;

  /// Source-time click timestamps for the active recording. Used as snap
  /// candidates when the user commits a scissors-mode cut. Sorted ascending.
  final List<Duration> cursorClickTimes;

  /// Fires with the edited-time snap target when a scissors-mode cut
  /// snapped to a candidate. The parent uses this to drive the snap flash.
  final ValueChanged<Duration>? onSnapped;

  /// Edited-time of the most recent snap target — drives [SnapFlashOverlay].
  /// Null when no recent snap has occurred or the fade has completed.
  /// The parent screen owns the lifecycle; the timeline only renders.
  final Duration? snapFlashTarget;

  @override
  ConsumerState<EditorTimeline> createState() => _EditorTimelineState();
}

class _EditorTimelineState extends ConsumerState<EditorTimeline>
    with TickerProviderStateMixin {
  // Clip-lane float: gentle continuous up/down bob while cut mode is
  // active. Linear ticks; the builder sin-maps to ±2 px so the motion
  // is smooth without easing the controller itself.
  late final AnimationController _laneFloat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  // Pin mix: 0 = freely floating, 1 = pinned down at the dip. Driven
  // forward when the cut cursor enters proximity of the lane, reversed
  // when it leaves. Slow on purpose — the bar should "lean in" toward
  // the user, not snap.
  late final AnimationController _lanePin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  // Pinned-down resting position when the cursor is near the lane.
  static const double _kPinDy = 3.0;
  double? _hoverProgress;
  final ScrollController _scrollController = ScrollController();
  // Fallback no-op cursor source so SliceBars always have something to
  // listen to — used when cut mode is off and the caller hasn't passed
  // its own cursorXListenable.
  final ValueNotifier<double?> _nullCursor = ValueNotifier<double?>(null);
  // Live cut-mode cursor x, owned by the timeline state (lifecycle
  // outlives the conditional CutOverlay so SliceBars don't re-subscribe
  // every time the overlay mounts/unmounts).
  final ValueNotifier<double?> _cutCursorX = ValueNotifier<double?>(null);
  // Same lifecycle as [_cutCursorX]; tracks the cursor's local-y inside
  // the cut overlay so the clip lane can magnetic-track to it.
  final ValueNotifier<double?> _cutCursorY = ValueNotifier<double?>(null);
  double _lastViewportWidth = 0;
  // Captured at onScaleStart so each ongoing pinch computes
  // (start * d.scale) rather than compounding across frames.
  double? _pinchStartScale;
  // Last global pointer position seen by onHover. Used to distinguish
  // a real cursor move from a hover event synthesized when the scrolled
  // content shifts under a stationary cursor (two-finger trackpad
  // scroll at scale > 1). The visual hover indicator should follow the
  // content under the cursor, but the playhead must NOT seek unless
  // the user actually moved the pointer.
  Offset? _lastHoverGlobal;

  // True while [_maybeAutoFollow] or [_applyScale] is driving the
  // scroll controller via jumpTo. The scroll listener uses this to
  // distinguish our own programmatic scrolls (which shouldn't disable
  // auto-follow) from genuine user-initiated scrolls (which should).
  bool _programmaticScrollInProgress = false;

  // Set to true when the user manually scrolls the timeline during
  // playback. Suppresses auto-follow for the rest of the current play
  // session. Resets on every isPlaying transition so a fresh play
  // session re-engages auto-follow.
  bool _userOverrodeScroll = false;

  // True while ANY slice's trim handle is being dragged. Drives a
  // fade on the playhead + hover-cursor overlay so they don't fight
  // the bloom/dim-bands visual while the user is trimming.
  bool _trimDragging = false;
  static const Duration _kTrimFadeDuration = Duration(milliseconds: 180);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _cutCursorY.addListener(_onCutCursorYChanged);
    if (widget.cutModeActive) _laneFloat.repeat();
  }

  void _onCutCursorYChanged() {
    final near = widget.cutModeActive && _cutCursorY.value != null;
    if (near) {
      _lanePin.forward();
    } else {
      _lanePin.reverse();
    }
  }

  void _onScroll() {
    // Ignore our own programmatic jumps (auto-follow + anchor-preserve);
    // treat any other scroll change while playing as a user override.
    if (_programmaticScrollInProgress) return;
    if (widget.isPlaying && widget.timelineScale > 1.0) {
      _userOverrodeScroll = true;
    }
  }

  void _updateHover(Offset local, double width, {Offset? global}) {
    if (widget.isPlaying || width <= 0) return;
    // Compute progress as a fraction of CONTENT width, not viewport
    // width — at scale > 1 the cursor's viewport-x corresponds to
    // (viewport_x + scrollOffset) in content coords.
    final scrollOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final progress = _progressFromHover(
      local.dx,
      scrollOffset,
      width,
      widget.timelineScale,
    );
    if (_hoverProgress != progress) {
      setState(() => _hoverProgress = progress);
    }
    // Two-finger trackpad scroll at scale > 1 makes Flutter re-dispatch
    // onHover events as the content shifts under a stationary cursor,
    // even though the cursor's global position is unchanged. Treat that
    // as a scroll (not a scrub) — only call onHoverSeek when the global
    // pointer position actually moved.
    final didPointerMove = global == null ||
        _lastHoverGlobal == null ||
        global != _lastHoverGlobal;
    _lastHoverGlobal = global;
    if (didPointerMove && widget.onHoverSeek != null) {
      final hoverTime = Duration(
        microseconds: (widget.duration.inMicroseconds * progress).round(),
      );
      widget.onHoverSeek!(hoverTime);
    }
  }

  void _clearHover() {
    final wasHovering = _hoverProgress != null;
    if (wasHovering) {
      setState(() => _hoverProgress = null);
    }
    _lastHoverGlobal = null;
    if (wasHovering) widget.onHoverEnd?.call();
  }

  /// Cut-mode vertical proximity to the clip lane. When the cursor is
  /// within [proximity] px of the lane (vertically), publishes its
  /// lane-local y so the lane snaps out of float and into magnetic
  /// pull. When far away, nulls out so the lane resumes floating.
  /// Drives [_cutCursorY] only — [_cutCursorX] stays owned by
  /// CutOverlay (it's tied to actually-inside-the-lane cut commits).
  void _updateCutProximity(double localYInTimeline) {
    if (!widget.cutModeActive) {
      if (_cutCursorY.value != null) _cutCursorY.value = null;
      return;
    }
    const proximity = 40.0;
    final laneTop = rulerHeight + laneSpacing + CutMarker.kHitHeight;
    final laneBottom = laneTop + laneHeight;
    final y = localYInTimeline;
    if (y >= laneTop - proximity && y <= laneBottom + proximity) {
      _cutCursorY.value = (y - laneTop).clamp(0.0, laneHeight);
    } else {
      if (_cutCursorY.value != null) _cutCursorY.value = null;
    }
  }

  @override
  void didUpdateWidget(EditorTimeline old) {
    super.didUpdateWidget(old);
    if (widget.cutModeActive != old.cutModeActive) {
      if (widget.cutModeActive) {
        // Pin starts at 0 (free-floating); will animate to +3 if the
        // cursor is already over the lane when the listener fires.
        _laneFloat.repeat();
      } else {
        _laneFloat.stop();
        _laneFloat.value = 0;
        _cutCursorY.value = null;
        _lanePin.reverse();
      }
    }
    // If playback resumes, the hover indicator should disappear.
    if (widget.isPlaying && _hoverProgress != null) {
      _hoverProgress = null;
    }
    // Reset the user-scroll override on every isPlaying transition so
    // a fresh play session re-engages auto-follow. (Scale changes
    // intentionally do NOT reset the override — pinching to a new zoom
    // level shouldn't undo a deliberate scroll-away.)
    if (widget.isPlaying != old.isPlaying) {
      _userOverrodeScroll = false;
    }

    final scaleChanged = widget.timelineScale != old.timelineScale;
    final anchorPresent = widget.pendingScaleAnchor != null;
    if (scaleChanged || anchorPresent) {
      // Defer to post-frame so LayoutBuilder has run and the
      // SingleChildScrollView's content has been measured with the new
      // width before we jumpTo.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyScale(old.timelineScale, widget.timelineScale,
            widget.pendingScaleAnchor);
      });
    }

    if (widget.position != old.position) {
      // Defer to post-frame so the new scale (if it changed in the same
      // build) has been applied first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeAutoFollow(widget.position);
      });
    }
  }

  void _maybeAutoFollow(Duration playhead) {
    if (!widget.isPlaying) return;
    if (widget.timelineScale == 1.0) return;
    // The user scrolled the timeline this play session — respect that
    // and don't snap them back. Resets on the next play/pause edge.
    if (_userOverrodeScroll) return;

    final viewport = _lastViewportWidth;
    if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;

    final pps = pixelsPerSecond(viewport, widget.duration, widget.timelineScale);
    final playheadContentX = timeToX(playhead, pps);
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final playheadViewportX = playheadContentX - offset;

    if (playheadViewportX > 0.8 * viewport || playheadViewportX < 0) {
      final targetOffset = playheadContentX - 0.2 * viewport;
      final maxOffset = (contentWidth(viewport, widget.timelineScale) - viewport)
          .clamp(0.0, double.infinity);
      if (_scrollController.hasClients) {
        _programmaticScrollInProgress = true;
        try {
          _scrollController.jumpTo(targetOffset.clamp(0.0, maxOffset));
        } finally {
          _programmaticScrollInProgress = false;
        }
      }
    }
  }

  void _applyScale(double oldScale, double newScale, Duration? anchor) {
    final viewport = _lastViewportWidth;
    if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;
    final anchorTime = anchor ?? widget.position;

    final oldPps = pixelsPerSecond(viewport, widget.duration, oldScale);
    final newPps = pixelsPerSecond(viewport, widget.duration, newScale);
    final oldOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;

    final anchorViewportX = timeToX(anchorTime, oldPps) - oldOffset;
    final newAnchorContentX = timeToX(anchorTime, newPps);
    final newOffset = newAnchorContentX - anchorViewportX;

    final maxOffset = (contentWidth(viewport, newScale) - viewport)
        .clamp(0.0, double.infinity);
    final clamped = newOffset.clamp(0.0, maxOffset);

    if (_scrollController.hasClients) {
      // Guard with the programmatic flag so the scroll listener doesn't
      // mistake an anchor-preserve jump for a user-initiated scroll.
      _programmaticScrollInProgress = true;
      try {
        _scrollController.jumpTo(clamped);
      } finally {
        _programmaticScrollInProgress = false;
      }
    }

    if (anchor != null) {
      widget.onAnchorConsumed?.call();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _cutCursorY.removeListener(_onCutCursorYChanged);
    _laneFloat.dispose();
    _lanePin.dispose();
    _nullCursor.dispose();
    _cutCursorX.dispose();
    _cutCursorY.dispose();
    super.dispose();
  }

  /// Maps the overlay's click x to an edited-time and asks the engine
  /// to split. Returns false when the split was rejected (e.g. too
  /// close to a cut boundary) so the caller can leave cut mode active
  /// for another attempt.
  ///
  /// Applies snap when the global toggle is on and [overrideSnap] is
  /// false; mirrors the Cmd+K path in PlaybackScreen.
  bool _attemptSplit(Duration editedTime, {required bool overrideSnap}) {
    final clips = widget.clips;
    final snapEnabled = ref.read(snapPreferenceProvider);
    final zoomEdges = <Duration>[
      for (final r in ref
          .read(editorProjectControllerProvider)
          .timeline
          .activeZoomRegions) ...[r.startTime, r.endTime],
    ];
    final decision = decideCut(
      playheadEdited: editedTime,
      clips: clips,
      clickTimesSource: widget.cursorClickTimes,
      zoomEdgesSource: zoomEdges,
      snapEnabled: snapEnabled,
      overrideSnap: overrideSnap,
    );
    final controller =
        ref.read(editorProjectControllerProvider.notifier);
    final snappedOk = controller.splitAtPlayhead(decision.time, clips);
    if (snappedOk) {
      if (decision.snapTarget != null) {
        widget.onSnapped?.call(decision.snapTarget!);
      }
      widget.onSliceSelected?.call(null);
      return true;
    }
    if (decision.snapTarget != null) {
      // Snap pushed us into the min-slice guard zone — retry at the
      // raw tap position so the user's gesture still produces a cut
      // when it would have otherwise succeeded. No snap flash on this
      // path because we did NOT land on the snap target. Mirrors the
      // Cmd+K fallback in PlaybackScreen._onKey.
      final rawOk = controller.splitAtPlayhead(editedTime, clips);
      if (rawOk) {
        widget.onSliceSelected?.call(null);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Intentional build-time side effect: cache the latest viewport
        // width so G3's anchor-preserve math can read it without an
        // extra LayoutBuilder round-trip.
        _lastViewportWidth = width;
        final pps = pixelsPerSecond(
            width, widget.duration, widget.timelineScale);
        final cw = contentWidth(width, widget.timelineScale);
        // Zoom lane is always rendered, even when empty, so users can
        // hover/click an empty patch to add a new zoom.
        final zoomLaneHeight = laneHeight + zoomBadgeAreaHeight;
        final totalHeight = rulerHeight +
            laneSpacing +
            CutMarker.kHitHeight +
            laneHeight +
            laneSpacing +
            zoomLaneHeight;

        return SizedBox(
          height: totalHeight,
          width: width,
          child: GestureDetector(
            // Trackpad pinch → zoom the timeline anchored at the cursor.
            // `translucent` so single-finger taps/drags still reach the
            // lane gesture detectors underneath; we only consume events
            // once a true two-finger pinch is recognized.
            behavior: HitTestBehavior.translucent,
            onScaleStart: (_) => _pinchStartScale = widget.timelineScale,
            onScaleUpdate: (d) {
              // Filter out single-finger drags: pointerCount < 2 OR
              // scale == 1 (one-finger pan reports scale == 1.0). Those
              // belong to the SingleChildScrollView / lane handlers.
              if (d.pointerCount < 2 || d.scale == 1.0) return;
              final start = _pinchStartScale ?? widget.timelineScale;
              final next = (start * d.scale).clamp(1.0, 8.0);

              final viewport = _lastViewportWidth;
              if (viewport <= 0) return;
              final offset = _scrollController.hasClients
                  ? _scrollController.offset
                  : 0.0;
              final pps = pixelsPerSecond(
                  viewport, widget.duration, widget.timelineScale);
              final anchorContentX = d.localFocalPoint.dx + offset;
              final anchorTime = xToTime(anchorContentX, pps);
              widget.onPinchScale?.call(next, anchorTime);
            },
            onScaleEnd: (_) => _pinchStartScale = null,
            child: MouseRegion(
            // Hover-to-scrub when paused. The MouseRegion sits above the
            // gesture detectors but doesn't consume events — onHover is
            // hover-only, onTap/onPan still flow through to the lanes
            // below.
            opaque: false,
            onHover: (e) {
              _updateHover(e.localPosition, width, global: e.position);
              _updateCutProximity(e.localPosition.dy);
            },
            onExit: (_) {
              _clearHover();
              _cutCursorY.value = null;
            },
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: widget.timelineScale > 1.0
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: cw,
                height: totalHeight,
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: rulerHeight,
                          child: TimeRuler(
                            duration: widget.duration,
                            pixelsPerSecond: pps,
                            contentWidth: cw,
                            onSeek: widget.onSeek,
                          ),
                        ),
                        const SizedBox(height: laneSpacing),
                        SizedBox(
                          height: CutMarker.kHitHeight,
                          child: CutMarkerStrip(
                            clips: widget.clips,
                            pixelsPerSecond: pps,
                            onClearSeamTrims: (i) =>
                                widget.onClearSeamTrims?.call(i),
                            onMergeSeam: (i) =>
                                widget.onMergeSeam?.call(i),
                            dragging: _trimDragging,
                          ),
                        ),
                        SizedBox(
                          height: laneHeight,
                          child: Stack(
                            // Clip.none so the selected slice's outer
                            // glow can extend vertically past the lane.
                            clipBehavior: Clip.none,
                            children: [
                              // Clip-lane hover effect:
                              //   - Cut mode on, cursor NOT near lane:
                              //     slices float ±2px sin (1800ms).
                              //   - Cut mode on, cursor near or over
                              //     lane: slow lean into pinned dy
                              //     (~700ms ease) — float mixes out.
                              //   - Cut mode off: dy = 0.
                              AnimatedBuilder(
                                animation: Listenable.merge(
                                    [_laneFloat, _lanePin]),
                                builder: (context, child) {
                                  final floatDy = math.sin(
                                          _laneFloat.value * 2 * math.pi) *
                                      2.0;
                                  final pinT = Curves.easeOutCubic
                                      .transform(_lanePin.value);
                                  final dy = floatDy * (1 - pinT)
                                      + _kPinDy * pinT;
                                  return Transform.translate(
                                    offset: Offset(0, dy),
                                    child: child,
                                  );
                                },
                                child: ClipLane(
                                  clips: widget.clips,
                                  selectedSliceIndex:
                                      widget.selectedSliceIndex,
                                  pixelsPerSecond: pps,
                                  onSliceSelected: (i) =>
                                      widget.onSliceSelected?.call(i),
                                  onSliceTrimStartChanged: (i, v) =>
                                      widget.onSliceTrimStartChanged
                                          ?.call(i, v),
                                  onSliceTrimEndChanged: (i, v) =>
                                      widget.onSliceTrimEndChanged
                                          ?.call(i, v),
                                  onTrimDragChanged: (active) {
                                    if (_trimDragging != active) {
                                      setState(
                                          () => _trimDragging = active);
                                    }
                                  },
                                ),
                              ),
                              if (widget.cutModeActive)
                                Positioned.fill(
                                  child: CutOverlay(
                                    pixelsPerSecond: pps,
                                    totalEditedDuration: widget.duration,
                                    cursorX: _cutCursorX,
                                    onCommitCut: (editedTime, {required bool overrideSnap}) {
                                      final ok = _attemptSplit(editedTime, overrideSnap: overrideSnap);
                                      if (ok) {
                                        widget.onCutModeChanged?.call(false);
                                      }
                                    },
                                    onExitMode: () =>
                                        widget.onCutModeChanged?.call(false),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: laneSpacing),
                        TipAnchor(
                          tipId: TipId.editorZoomKeyframe,
                          child: SizedBox(
                            height: zoomLaneHeight,
                            child: ZoomLane(
                              duration: widget.duration,
                              pixelsPerSecond: pps,
                              contentWidth: cw,
                              zoomRegions: widget.zoomRegions,
                              clips: widget.clips,
                              selectedIndex: widget.selectedZoomIndex,
                              onZoomChanged: widget.onZoomChanged,
                              onZoomSelected: widget.onZoomSelected,
                              onZoomDeleted: widget.onZoomDeleted,
                              onZoomAdded: widget.onZoomAdded,
                              onSeek: widget.onSeek,
                            ),
                          ),
                        ),
                      ],
                    ),
                    IgnorePointer(
                      // Fades the playhead AND hover indicator out as
                      // a trim drag starts — both are painted by the
                      // same PlayheadPainter, so a single AnimatedOpacity
                      // covers them. Restored on drag end/cancel. The
                      // RepaintBoundary isolates per-frame `progress`
                      // updates so the playhead's own layer is the only
                      // thing that repaints — otherwise the AnimatedOpacity
                      // subtree above it would invalidate at content-width
                      // scope and we'd see micro-stutters when the playhead
                      // crosses slice seams.
                      child: AnimatedOpacity(
                        duration: _kTrimFadeDuration,
                        curve: Curves.easeOut,
                        opacity: _trimDragging ? 0.0 : 1.0,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            size: Size(cw, totalHeight),
                            painter: PlayheadPainter(
                              progress: widget.duration.inMicroseconds == 0
                                  ? 0
                                  : (widget.position.inMicroseconds /
                                          widget.duration.inMicroseconds)
                                      .clamp(0.0, 1.0),
                              hoverProgress:
                                  widget.isPlaying ? null : _hoverProgress,
                              rulerHeight: rulerHeight,
                              flashOn: widget.playheadFlashOn,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: SizedBox(
                        width: cw,
                        height: totalHeight,
                        child: SnapFlashOverlay(
                          target: widget.snapFlashTarget,
                          editedTimeToPx: (d) => timeToX(d, pps),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}
