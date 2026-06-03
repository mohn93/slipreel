import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:screen_recorder/onboarding/tip_anchor.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/ui/widgets/timeline/clip_lane.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_overlay.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';
import 'package:screen_recorder/ui/widgets/timeline/time_ruler.dart';
import 'package:screen_recorder/ui/widgets/timeline/snap_flash_overlay.dart';

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

class _EditorTimelineState extends ConsumerState<EditorTimeline> {
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

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
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

  @override
  void didUpdateWidget(EditorTimeline old) {
    super.didUpdateWidget(old);
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
    _nullCursor.dispose();
    _cutCursorX.dispose();
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
    final ok = ref
        .read(editorProjectControllerProvider.notifier)
        .splitAtPlayhead(decision.time, clips);
    if (ok && decision.snapTarget != null) {
      widget.onSnapped?.call(decision.snapTarget!);
    }
    if (ok) widget.onSliceSelected?.call(null);
    return ok;
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
            onHover: (e) => _updateHover(e.localPosition, width, global: e.position),
            onExit: (_) => _clearHover(),
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
                          height: laneHeight,
                          child: Stack(
                            children: [
                              ClipLane(
                                clips: widget.clips,
                                selectedSliceIndex: widget.selectedSliceIndex,
                                pixelsPerSecond: pps,
                                // Cut mode wires SliceBars to the live
                                // cut-overlay cursor; off-mode falls back
                                // to the caller's listenable (or our
                                // no-op notifier).
                                cursorXListenable: widget.cutModeActive
                                    ? _cutCursorX
                                    : (widget.cursorXListenable ??
                                        _nullCursor),
                                onSliceSelected: (i) =>
                                    widget.onSliceSelected?.call(i),
                                onSliceTrimStartChanged: (i, v) =>
                                    widget.onSliceTrimStartChanged?.call(i, v),
                                onSliceTrimEndChanged: (i, v) =>
                                    widget.onSliceTrimEndChanged?.call(i, v),
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
                            child: _ZoomLane(
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
                      child: CustomPaint(
                        size: Size(cw, totalHeight),
                        painter: _PlayheadPainter(
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

// ─────────────────────────────── Zoom lane ──────────────────────────────

class _ZoomLane extends StatefulWidget {
  const _ZoomLane({
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
  State<_ZoomLane> createState() => _ZoomLaneState();
}

class _ZoomLaneState extends State<_ZoomLane> {
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

// ──────────────────────────────── Playhead ──────────────────────────────

class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter({
    required this.progress,
    required this.hoverProgress,
    required this.rulerHeight,
    this.flashOn = false,
  });

  final double progress;
  final double? hoverProgress;
  final double rulerHeight;
  /// When true, the line/knob gradient swaps to a solid accent fill
  /// signalling a rejected Cmd+K cut. The parent holds this true for
  /// 120ms before flipping it back; this painter just renders the
  /// current snapshot.
  final bool flashOn;

  static const Color _flashAccent = Color(0xFF6C63FF);

  static const _knobRadius = 6.5;
  static const _lineWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Hover preview indicator (drawn first, so the regular playhead
    // sits on top when both end up at the same x). Only present when
    // the cursor is hovering the timeline and playback is paused.
    if (hoverProgress != null) {
      final hx = size.width * hoverProgress!;
      final hoverPaint = Paint()
        ..color = const Color(0x99FFFFFF)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(hx, rulerHeight - 2),
        Offset(hx, size.height),
        hoverPaint,
      );
      // Small ring at the top so the ghost reads as an indicator,
      // not a stray line.
      canvas.drawCircle(
        Offset(hx, rulerHeight - 6),
        4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xCCFFFFFF),
      );
    }

    final x = size.width * progress;
    final knobCenter = Offset(x, _knobRadius);
    final lineTop = _knobRadius + _knobRadius - 1;
    final lineRect = Rect.fromLTWH(
      x - _lineWidth / 2,
      lineTop,
      _lineWidth,
      size.height - lineTop,
    );

    // ── Vertical line: blue → dark purple → transparent. The flash
    // path swaps the saturated colours for the accent so a rejected
    // Cmd+K reads as a deliberate signal, not a colour glitch.
    final lineGradient = flashOn
        ? const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _flashAccent,
              _flashAccent,
              _flashAccent,
              Color(0x006C63FF),
            ],
            stops: [0.0, 0.35, 0.7, 1.0],
          ).createShader(lineRect)
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              playheadTop,
              playheadMid,
              playheadBottom,
              Color(0x003D26AA),
            ],
            stops: [0.0, 0.35, 0.7, 1.0],
          ).createShader(lineRect);

    // Soft outer glow for the line.
    final glowPaint = Paint()
      ..shader = lineGradient
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..color = const Color(0xFF000000); // shader overrides; color carries alpha into mask
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        lineRect.inflate(0.5), const Radius.circular(2)),
      glowPaint,
    );

    // Solid line on top of the glow.
    canvas.drawRRect(
      RRect.fromRectAndRadius(lineRect, const Radius.circular(1.5)),
      Paint()..shader = lineGradient,
    );

    // ── Knob (button-like cap): drop shadow + outer glow + gradient fill +
    // inner highlight. Uses the same blue-to-purple palette but fully
    // opaque so it stays prominent.
    final knobRect = Rect.fromCircle(
      center: knobCenter,
      radius: _knobRadius,
    );
    final knobGradient = flashOn
        ? const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_flashAccent, _flashAccent],
          ).createShader(knobRect)
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [playheadTop, playheadBottom],
          ).createShader(knobRect);

    // Drop shadow underneath.
    canvas.drawCircle(
      knobCenter.translate(0, 1.5),
      _knobRadius,
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Soft outer cyan glow to tie the knob into the line.
    canvas.drawCircle(
      knobCenter,
      _knobRadius + 2,
      Paint()
        ..color = const Color(0x554FC3FF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Gradient fill.
    canvas.drawCircle(
      knobCenter,
      _knobRadius,
      Paint()..shader = knobGradient,
    );
    // Crisp 1px ring so the knob reads against light backgrounds too.
    canvas.drawCircle(
      knobCenter,
      _knobRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x88FFFFFF),
    );
    // Specular highlight.
    canvas.drawCircle(
      knobCenter.translate(0, -1.8),
      2.2,
      Paint()..color = const Color(0x88FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      old.progress != progress ||
      old.hoverProgress != hoverProgress ||
      old.rulerHeight != rulerHeight ||
      old.flashOn != flashOn;
}
