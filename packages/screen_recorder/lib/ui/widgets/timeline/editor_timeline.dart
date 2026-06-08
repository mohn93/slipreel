import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/models/keystroke_group.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';
import 'keystroke_timeline_lane.dart';
import 'package:screen_recorder/onboarding/tip_anchor.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/ui/widgets/timeline/clip_lane.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart'
    show TrimDragInfo, TrimSide;
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker_strip.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_overlay.dart';
import 'package:screen_recorder/ui/widgets/timeline/playhead_painter.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';
import 'package:screen_recorder/ui/widgets/timeline/time_ruler.dart';
import 'package:screen_recorder/ui/widgets/timeline/snap_flash_overlay.dart';
import 'package:screen_recorder/ui/widgets/timeline/zoom_lane.dart';
import 'package:screen_recorder/ui/widgets/timeline/camera_lane.dart';
import 'package:slipreel_engine/models/camera_region.dart';

/// Computes the hover-scrub progress fraction (0..1 of total content)
/// from the raw inputs that [_updateHover] has available.
///
///   viewportX   — cursor x relative to the viewport (MouseRegion local.dx)
///   scrollOffset — current [ScrollController.offset]
///   viewportWidth — effective content viewport (_timeAxisViewport(width)), NOT the raw LayoutBuilder width
///   scale       — widget.timelineScale
double _progressFromHover(
  double viewportX,
  double scrollOffset,
  double viewportWidth,
  double scale, {
  double padPx = 0.0,
}) {
  final content = contentWidth(viewportWidth, scale);
  if (content <= 0) return 0.0;
  // Content lives at SCH-x = [padPx, padPx + content]; convert the
  // cursor's viewport-x into a content-x by subtracting the live left
  // pad before normalizing. padPx breathes 0→_kEdgePadMax during edge
  // trim drags so the dim band has room past the slice body.
  final contentX = viewportX + scrollOffset - padPx;
  return (contentX / content).clamp(0.0, 1.0);
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
  double scale, {
  double padPx = 0.0,
}) => _progressFromHover(
  viewportX,
  scrollOffset,
  viewportWidth,
  scale,
  padPx: padPx,
);

/// Scroll behavior that opts the timeline's `SingleChildScrollView` out
/// of receiving trackpad gestures. With the default behavior, the
/// Scrollable's `HorizontalDragGestureRecognizer` competes for every
/// trackpad pan-zoom event against our top-level `ScaleGestureRecognizer`.
/// Even when our recognizer wins the arena for the scale portion, the
/// PAN portion of a two-finger pinch frequently leaks through to the
/// Scrollable and translates the offset — the user sees the content
/// drift while it zooms.
///
/// By excluding trackpad from `dragDevices`, the Scrollable simply
/// refuses to handle PointerPanZoom events. Every trackpad gesture
/// (pinch AND two-finger pan) is routed to our top-level handler,
/// which interprets scale changes as zoom and focal-point motion as
/// scroll. Mouse and stylus drags still go straight to the Scrollable;
/// touch is left to the top-level scale recognizer so two-finger pinch
/// cannot be stolen by the inner horizontal drag recognizer.
class _NoTrackpadScrollBehavior extends MaterialScrollBehavior {
  const _NoTrackpadScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };
}

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
    this.onClearStartTrim,
    this.onClearEndTrim,
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
    this.keystrokeRecording,
    this.keystrokeSettings = const KeystrokeOverlaySettings(),
    this.onKeystrokeToggle,
    this.cameraRegions = const [],
    this.selectedCameraIndex,
    this.onCameraChanged,
    this.onCameraSelected,
    this.onCameraDeleted,
    this.onCameraAdded,
  });

  final Duration duration;

  /// Playhead position as a listenable so per-vsync updates can drive
  /// only the playhead subtree (via `ValueListenableBuilder` inside
  /// `build`) without rebuilding the whole timeline widget tree on
  /// every tick. The parent updates `.value` from its smoothed
  /// extrapolator; the value is in edited-time units to match
  /// [duration].
  final ValueListenable<Duration> position;
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
  final void Function(int sliceIndex, Duration trimStart)?
  onSliceTrimStartChanged;
  final void Function(int sliceIndex, Duration trimEnd)? onSliceTrimEndChanged;

  /// Fired by [CutMarkerStrip] when the user taps a seam that has
  /// trimmed-away content — clears both trim handles so the full source
  /// footage is restored at that seam.
  final ValueChanged<int>? onClearSeamTrims;

  /// Fired by [CutMarkerStrip] when the user taps a clean seam (no hidden
  /// content) — merges the two adjacent slices into one.
  final ValueChanged<int>? onMergeSeam;

  /// Fired by [CutMarkerStrip] when the user taps the LEFT edge
  /// marker — restores the first slice's outer start-trim back to its
  /// cut bound.
  final VoidCallback? onClearStartTrim;

  /// Fired by [CutMarkerStrip] when the user taps the RIGHT edge
  /// marker — restores the last slice's outer end-trim back to its
  /// cut bound.
  final VoidCallback? onClearEndTrim;

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

  /// Captured keystrokes for the recording, laid out in the optional
  /// shortcuts timeline lane. Null when the recording has no keystroke data.
  final KeystrokeRecording? keystrokeRecording;

  /// Keystroke overlay settings — gate the lane on [enabled] + [showTimeline]
  /// and reuse the display filter for which events appear.
  final KeystrokeOverlaySettings keystrokeSettings;

  /// Fired when a shortcuts-lane bar is tapped to toggle that occurrence
  /// on/off. The parent flips the group's member timestamps in the project's
  /// disabled set.
  final ValueChanged<KeystrokeGroup>? onKeystrokeToggle;

  final List<CameraRegion> cameraRegions;
  final int? selectedCameraIndex;
  final void Function(int, CameraRegion)? onCameraChanged;
  final ValueChanged<int?>? onCameraSelected;
  final ValueChanged<int>? onCameraDeleted;
  final void Function(Duration start, Duration end)? onCameraAdded;

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
  // Shortcuts-lane reveal: 0 = collapsed, 1 = fully shown. Animates the lane
  // in/out when "Show shortcuts" / the timeline toggle flips, growing its
  // height + fading. setState on each tick re-runs the timeline build so the
  // total height and playhead extent track the animation.
  late final AnimationController _laneRevealCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _laneReveal = CurvedAnimation(
    parent: _laneRevealCtl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  bool _keystrokeLaneWanted(EditorTimeline w) =>
      w.keystrokeSettings.enabled &&
      w.keystrokeSettings.showTimeline &&
      w.keystrokeRecording != null;

  void _onLaneRevealTick() {
    if (mounted) setState(() {});
  }

  // Top y (timeline-local) of the shortcuts-lane block while it is showing —
  // taps below this drive bar toggles, not playhead seeks. Null when hidden.
  double? _keystrokeLaneTopY;
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
  // Anchor TIME for the pinch — kept stable so finger micro-jitter
  // doesn't feed back as scroll-offset wobble. Recomputing it from
  // `d.localFocalPoint` every update makes each frame's anchor land
  // a few µs earlier or later in source time, _applyScale snaps to
  // the new anchor, repeat — the user sees the content shimmer
  // instead of zooming smoothly around a fixed point.
  //
  // Initialized at gesture-start. Re-derived ONCE, at the first
  // pinch frame this gesture, if (and only if) panning happened
  // before pinch — otherwise the locked-at-start time would be far
  // off-screen by the time the user finally pinches, and pinning to
  // it would visibly snap the content. See [_pinchHasScaled].
  Duration? _pinchAnchorTime;
  // The pivot's on-screen x. Trackpad pan/zoom reports a focal point
  // that includes the pan component, so this is updated on every pinch
  // frame while [_pinchAnchorTime] stays locked. _applyScale keeps that
  // source-time pinned to the live focal x as the smoothed scale ramps,
  // so the content follows the user's fingers without feeding focal
  // jitter back into the semantic time anchor.
  double? _pinchAnchorViewportX;
  // Sticky "this gesture has been a pinch" flag. Flips true the
  // first frame |d.scale - 1| crosses threshold, stays until
  // onScaleEnd. Used to (a) suppress the pan path on noisy sub-eps
  // frames mid-pinch (without this, scale streams that briefly dip
  // back below threshold cause a one-frame scroll twitch) and
  // (b) trigger the one-shot re-derivation of [_pinchAnchorTime]
  // described above.
  bool _pinchHasScaled = false;
  // VSYNC-driven pinch-scale smoothing.
  //
  // Trackpad scale events do NOT arrive 1:1 with frames — some frames
  // get two events, some get none. Smoothing at event time and painting
  // at vsync therefore resamples the motion unevenly, producing a
  // regular every-other-frame velocity alternation (measured ~2× swing)
  // that reads as shimmer. The fix: input events only record the latest
  // raw target ([_rawTargetScale]); a Ticker advances the applied scale
  // ([_renderScale]) toward it exactly once per frame via a time-based
  // EMA. Render cadence is now independent of event cadence.
  Ticker? _pinchTicker;
  double? _rawTargetScale;
  double _renderScale = 1.0;
  Duration _lastPinchElapsed = Duration.zero;
  // True when the current two-finger gesture stayed in pan mode. We
  // use it at onScaleEnd to hand the release velocity to Flutter's
  // bouncing scroll physics, giving trackpad pans iOS-style momentum
  // without letting pinch frames leak sideways.
  bool _trackpadPanActive = false;
  double _trackpadPanVelocityX = 0.0;
  Duration? _lastTrackpadPanTime;
  int? _tapSeekPointer;
  Offset? _tapSeekDownLocal;
  bool _tapSeekMoved = false;
  bool _tapSeekBlocked = false;
  // True between onScaleEnd and the ticker settling onto the final
  // target. Keeps the ticker applying (so the scale lands exactly on
  // the user's intended zoom) until converged, then stops.
  bool _pinchReleasing = false;
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

  /// Full payload of the active trim drag (slice index + side), so
  /// the CutMarkerStrip can keep the corresponding marker at full
  /// opacity while the others fade. Mirrors [_trimDragging] but with
  /// the extra (which-edge) detail the strip needs to identify the
  /// active marker.
  TrimDragInfo? _activeTrimDrag;
  static const Duration _kTrimFadeDuration = Duration(milliseconds: 180);
  static const double _kTapSeekSlop = 8.0;
  // Edge pad model — drives the breathing room at the timeline's
  // start/end during edge-handle trim drags so the dim band stays
  // in view instead of overflowing the viewport edge.
  //
  // Each pad value = bloomCtl.value * targetPx, where:
  //   bloomCtl is a 0→1 controller that forwards on drag start and
  //   reverses on drag end (220 ms ease curve, matched to SliceBar's
  //   internal _expand so the pad grows lockstep with the dim band).
  //
  //   targetPx is recomputed in build() from the current clip's trim
  //   data — bandLeftTarget = (clip0.trimStart - clip0.cutStart) in
  //   pixels, bandRightTarget = (lastClip.cutEnd - lastClip.trimEnd)
  //   in pixels. As the user trims further, targetPx grows; leftPad
  //   updates immediately because we read targetPx fresh each frame.
  //
  // Scroll behavior on bloom (existing trim, drag just started):
  //   LEFT case: scrollOffset stays put. leftPad grows, content
  //     shifts right by leftPad, dim band appears in the new space
  //     between viewport-x=0 and the slice body. The slice body's
  //     left edge naturally moves with the growing pad — the user's
  //     cursor was on the handle but the gesture is delta-based, so
  //     even brief vp-divergence during the 220 ms bloom doesn't
  //     break the drag.
  //   RIGHT case: scrollOffset += bandRightTarget_at_drag_start over
  //     bloom so the content shifts LEFT and the band stays visible
  //     at the right edge of the viewport. Without this the band
  //     would extend into newly-extended scrollable territory that
  //     the user isn't auto-scrolled to.
  //
  // During the drag itself, targetPx changes (trim grows) but
  // scrollOffset does NOT — that way the body's edge tracks the
  // cursor 1:1 instead of doubling.
  //
  // On drag end the bloomCtl reverses 1→0. We lerp scrollOffset back
  // from its drag-end value to its drag-start value so the timeline
  // returns to the layout it started with — see [_onEdgePadTick].
  static const Duration _kPadAnimDuration = Duration(milliseconds: 220);
  // Mirrors SliceBar._kDimMaxPx — both must agree so the pad fits
  // the capped band exactly. If you change one, change the other.
  static const double _kDimMaxPx = 200.0;
  // Extra room around the capped band so its scissors + label sit
  // with a visible margin from the viewport edge, not flush against
  // it. Pad fullness = bandTarget + buffer.
  static const double _kEdgePadBuffer = 20.0;
  // Always-visible breathing room at the start/end of the timeline.
  // This is part of the scrollable canvas, not padding around the
  // ScrollView, so the viewport clips one coherent scroll surface.
  static const double _kScrollEdgeInset = 20.0;
  late final AnimationController _padCtlLeft = AnimationController(
    vsync: this,
    duration: _kPadAnimDuration,
  );
  late final AnimationController _padCtlRight = AnimationController(
    vsync: this,
    duration: _kPadAnimDuration,
  );
  // The bandTarget pixel value RIGHT NOW based on the current clips
  // (recomputed in build, lives across builds). Multiplied by the
  // bloom controllers' values to get the actual pad and scroll.
  double _bandLeftTargetPx = 0.0;
  double _bandRightTargetPx = 0.0;
  // The scroll offset captured at drag start AND drag end. During
  // the drag's bloom + drag + unbloom lifecycle, scrollOffset moves
  // from start → end during bloom (for right-edge drags only),
  // stays at end during drag, lerps back to start during unbloom.
  // null when no edge drag is in flight.
  double? _scrollOffsetAtDragStart;
  double? _scrollOffsetAtDragEnd;
  // The bandRightTarget at the moment a right-edge drag began.
  // Frozen so the right-edge bloom's auto-scroll uses the trim that
  // existed when the gesture started, not the live (growing) trim —
  // see the long comment above for why the frozen value is what
  // keeps the body tracking the cursor 1:1 during the drag.
  double _bandRightTargetAtDragStart = 0.0;
  // Last slice's right edge in content-x at the moment a right-edge
  // drag began. The visual band is capped at [_kDimMaxPx], which
  // means once the user has trimmed enough to bind the cap, the
  // band's right edge in content coords actually moves with the
  // body (= body.right + 200, not body.right + full ghost). To keep
  // the band's RIGHT EDGE pinned in the viewport across drag motion,
  // we continuously re-target scrollOffset against the body's
  // current right-edge minus this drag-start snapshot.
  double? _bodyRightContentXAtDragStart;
  // Which edge (if any) is currently being trimmed. Drives whether
  // a pad/scroll change is applied per [_onEdgePadTick].
  TrimSide? _activeEdgeSide;
  double get _leftPadPx =>
      _padCtlLeft.value * (_bandLeftTargetPx + _kEdgePadBuffer);
  double get _rightPadPx =>
      _padCtlRight.value * (_bandRightTargetPx + _kEdgePadBuffer);
  double get _scrollLeftInset => _kScrollEdgeInset + _leftPadPx;
  double get _scrollRightInset => _kScrollEdgeInset + _rightPadPx;
  double _timeAxisViewport(double viewport) =>
      math.max(0.0, viewport - 2 * _kScrollEdgeInset);
  double _timeAxisPps(double viewport, Duration duration, double scale) =>
      pixelsPerSecond(_timeAxisViewport(viewport), duration, scale);
  double _timeAxisContentWidth(double viewport, double scale) =>
      contentWidth(_timeAxisViewport(viewport), scale);
  double _scrollableWidth(double viewport, double scale) =>
      _timeAxisContentWidth(viewport, scale) +
      _scrollLeftInset +
      _scrollRightInset;
  double _maxScrollOffset(double viewport, double scale) =>
      (_scrollableWidth(viewport, scale) - viewport).clamp(
        0.0,
        double.infinity,
      );

  /// First slice's outer (left-side) trim in edited pixels — same
  /// formula SliceBar uses internally for its left dim band, capped
  /// at [_kDimMaxPx] so the pad never exceeds what's needed to fit
  /// the (capped) band plus its buffer.
  double _ghostPxForFirstSlice(double pps) {
    if (widget.clips.isEmpty) return 0.0;
    final s = widget.clips.first;
    final source = s.trimStart - s.cutStart;
    if (source <= Duration.zero) return 0.0;
    final speed = s.playbackSpeed > 0 ? s.playbackSpeed : 1.0;
    final raw = source.inMilliseconds / 1000.0 / speed * pps;
    return math.min(raw, _kDimMaxPx);
  }

  /// Last slice's outer (right-side) trim in edited pixels, capped.
  double _ghostPxForLastSlice(double pps) {
    if (widget.clips.isEmpty) return 0.0;
    final s = widget.clips.last;
    final source = s.cutEnd - s.trimEnd;
    if (source <= Duration.zero) return 0.0;
    final speed = s.playbackSpeed > 0 ? s.playbackSpeed : 1.0;
    final raw = source.inMilliseconds / 1000.0 / speed * pps;
    return math.min(raw, _kDimMaxPx);
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _cutCursorY.addListener(_onCutCursorYChanged);
    widget.position.addListener(_onPositionTick);
    _padCtlRight.addListener(_onEdgePadTick);
    // When the unbloom finishes, clear the active-side flag so the
    // tick handler stops trying to scroll. We CAN'T null it in
    // [_setTrimDragging(null)] because the unbloom needs
    // [_activeEdgeSide] to gate its lerp-back behavior.
    _padCtlRight.addStatusListener(_onPadCtlRightStatus);
    _padCtlLeft.addStatusListener(_onPadCtlLeftStatus);
    if (widget.cutModeActive) _laneFloat.repeat();
    _laneRevealCtl.value = _keystrokeLaneWanted(widget) ? 1.0 : 0.0;
    _laneRevealCtl.addListener(_onLaneRevealTick);
  }

  void _onPadCtlRightStatus(AnimationStatus s) {
    if (s == AnimationStatus.dismissed && _activeEdgeSide == TrimSide.right) {
      _activeEdgeSide = null;
      _scrollOffsetAtDragStart = null;
      _scrollOffsetAtDragEnd = null;
      _bodyRightContentXAtDragStart = null;
    }
  }

  void _onPadCtlLeftStatus(AnimationStatus s) {
    if (s == AnimationStatus.dismissed && _activeEdgeSide == TrimSide.left) {
      _activeEdgeSide = null;
      _scrollOffsetAtDragStart = null;
      _scrollOffsetAtDragEnd = null;
    }
  }

  /// Last slice's right edge in content-x, computed from current
  /// clip data. Used to track body shifts mid-drag so the auto-scroll
  /// can keep the (capped) dim band pinned in the viewport.
  double _computeBodyRightContentX() {
    final viewport = _lastViewportWidth;
    if (viewport <= 0 || widget.duration.inMilliseconds == 0) return 0.0;
    final pps = _timeAxisPps(viewport, widget.duration, widget.timelineScale);
    var total = 0.0;
    for (final c in widget.clips) {
      total += c.editedLength.inMilliseconds / 1000.0 * pps;
    }
    return total;
  }

  /// Called after a build in which the user just changed the right-
  /// edge trim. With the band visually capped at [_kDimMaxPx], the
  /// band's right edge in content coords is `body.right + 200` — so
  /// when the user is mid-cap-bound trim, `body.right` shifts but
  /// scrollOffset stays put, and the band drifts in viewport. This
  /// re-anchors it: scrollOffset = drag-start + buffer + current
  /// bandTarget + (body.right_now - body.right_at_drag_start).
  ///
  /// For uncapped trim the body and band move equal-and-opposite so
  /// the formula collapses to `drag-start + buffer + bandTarget`,
  /// which is exactly what the bloom set — no change. For capped
  /// trim the deltaBody term takes over, holding the band's right
  /// edge steady in viewport as the slice grows back into restoration.
  void _adjustScrollDuringRightDrag() {
    if (_activeEdgeSide != TrimSide.right) return;
    if (_padCtlRight.value < 1.0) return;
    final start = _scrollOffsetAtDragStart;
    if (start == null) return;
    final bodyRightStart = _bodyRightContentXAtDragStart;
    if (bodyRightStart == null) return;
    if (!_scrollController.hasClients) return;
    final viewport = _lastViewportWidth;
    if (viewport <= 0) return;
    final bodyRightNow = _computeBodyRightContentX();
    final deltaBody = bodyRightNow - bodyRightStart;
    final target = start + _kEdgePadBuffer + _bandRightTargetPx + deltaBody;
    final maxOff = _maxScrollOffset(viewport, widget.timelineScale);
    final clamped = target.clamp(0.0, maxOff);
    if ((_scrollController.offset - clamped).abs() < 0.5) return;
    _programmaticScrollInProgress = true;
    try {
      _scrollController.jumpTo(clamped);
    } finally {
      _programmaticScrollInProgress = false;
    }
  }

  /// Called on each tick of [_padCtlRight] — drives the auto-scroll
  /// for RIGHT-edge drags so the dim band stays visible at the
  /// viewport's right edge while the band balloons past the original
  /// content boundary. Linear lerp between
  /// [_scrollOffsetAtDragStart] and [_scrollOffsetAtDragEnd], indexed
  /// by the controller's progress value. Left-edge drags don't need a
  /// scroll change — the left pad naturally pushes content rightward
  /// as it grows, revealing the band in the new pad space — so the
  /// [_padCtlLeft] controller intentionally has no tick handler.
  ///
  /// Guarded by [_programmaticScrollInProgress] so [_onScroll] won't
  /// mis-flag this as a user override.
  void _onEdgePadTick() {
    if (_activeEdgeSide != TrimSide.right) return;
    final start = _scrollOffsetAtDragStart;
    if (start == null) return;
    // During bloom (drag in progress, status == forward), the
    // current end is start + frozenTarget. During unbloom (drag
    // released, status == reverse), the end is whatever scrollOffset
    // was when the drag ended — captured in [_setTrimDragging(null)].
    // Shift matches the full pad fullness — bandTarget + buffer —
    // so the band's right edge ends up just inside the viewport with
    // [_kEdgePadBuffer] px of margin, not flush against the edge.
    final shift = _bandRightTargetAtDragStart + _kEdgePadBuffer;
    final end = _padCtlRight.status == AnimationStatus.reverse
        ? (_scrollOffsetAtDragEnd ?? start + shift)
        : start + shift;
    final v = _padCtlRight.value;
    final target = start + (end - start) * v;
    if (!_scrollController.hasClients) return;
    // Don't trust `pos.maxScrollExtent` — it lags one frame behind
    // the pad controllers (the AnimatedBuilder hasn't relaid out yet
    // when this tick fires, so the live padding hasn't grown in the
    // viewport's view of its own extent). Recompute from the live
    // pad values instead, otherwise at scale=1 the target gets
    // clamped to 0 and the auto-scroll never moves.
    final viewport = _lastViewportWidth;
    if (viewport <= 0) return;
    final maxOff = _maxScrollOffset(viewport, widget.timelineScale);
    final clamped = target.clamp(0.0, maxOff);
    if ((_scrollController.offset - clamped).abs() < 0.5) return;
    _programmaticScrollInProgress = true;
    try {
      _scrollController.jumpTo(clamped);
    } finally {
      _programmaticScrollInProgress = false;
    }
  }

  /// Handles the (slice, side) info bubbled up from ClipLane. Drives
  /// the two pad controllers independently — only edge handles that
  /// could push the dim band off the viewport edge trigger pad
  /// expansion. Also flips [_trimDragging] for the playhead fade.
  void _setTrimDragging(TrimDragInfo? info) {
    final active = info != null;
    if (_trimDragging != active || _activeTrimDrag != info) {
      setState(() {
        _trimDragging = active;
        _activeTrimDrag = info;
      });
    }
    if (!active) {
      // Capture the scrollOffset at drag end so the unbloom lerp has
      // something to interpolate FROM as it reverses back to the
      // start value. Without this, lerping starts wherever pad's
      // current view of "end" is — and that view is based on the
      // frozen target captured at drag start, not the actual end.
      _scrollOffsetAtDragEnd = _scrollController.hasClients
          ? _scrollController.offset
          : null;
      _padCtlLeft.reverse();
      _padCtlRight.reverse();
      // NOTE: do NOT null _activeEdgeSide here — the unbloom needs
      // it to keep gating the tick handler's lerp-back behavior. The
      // status listeners (see initState) clear it on dismissed.
      return;
    }
    final lastIndex = widget.clips.length - 1;
    final isLeftEdgeDrag = info.sliceIndex == 0 && info.side == TrimSide.left;
    final isRightEdgeDrag =
        info.sliceIndex == lastIndex && info.side == TrimSide.right;
    // Snapshot the scroll position at the moment the drag starts —
    // the unbloom will lerp scrollOffset back to this on release.
    _scrollOffsetAtDragStart = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    _scrollOffsetAtDragEnd = null;
    if (isLeftEdgeDrag) {
      _activeEdgeSide = TrimSide.left;
      _padCtlLeft.forward();
    } else {
      _padCtlLeft.reverse();
    }
    if (isRightEdgeDrag) {
      _activeEdgeSide = TrimSide.right;
      // Freeze the bandRight target for auto-scroll math during the
      // bloom — see the header comment on _bandRightTargetAtDragStart.
      _bandRightTargetAtDragStart = _bandRightTargetPx;
      // Snapshot the body's right edge so the mid-drag scroll
      // adjuster can hold the (capped) band in viewport.
      _bodyRightContentXAtDragStart = _computeBodyRightContentX();
      _padCtlRight.forward();
    } else {
      _padCtlRight.reverse();
    }
    if (!isLeftEdgeDrag && !isRightEdgeDrag) _activeEdgeSide = null;
  }

  /// Auto-follow used to live in `didUpdateWidget` because position was
  /// a build-time prop and every parent rebuild fed a fresh value.
  /// Now position is a Listenable, so we drive auto-follow from its
  /// own notifications and the parent doesn't have to rebuild this
  /// widget per vsync.
  void _onPositionTick() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeAutoFollow(widget.position.value);
    });
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

  void _stopScrollActivity() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position is ScrollPositionWithSingleContext) {
      position.goIdle();
    }
  }

  void _applyTrackpadPan(double focalDeltaX) {
    if (focalDeltaX == 0 || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final scrollDelta = position.physics.applyPhysicsToUserOffset(
      position,
      focalDeltaX,
    );
    // Keep the pan under the user's fingers, including iOS-style
    // out-of-range resistance, but don't start a settle animation on
    // every event. Release-time goBallistic owns the bounce/momentum.
    // ignore: deprecated_member_use
    position.jumpToWithoutSettling(position.pixels - scrollDelta);
  }

  void _recordTrackpadPanVelocity(double focalDeltaX, Duration? timestamp) {
    final previous = _lastTrackpadPanTime;
    _lastTrackpadPanTime = timestamp;
    if (timestamp == null || previous == null) return;
    final dtSeconds = (timestamp - previous).inMicroseconds / 1000000.0;
    if (dtSeconds <= 0) return;
    final instant = -focalDeltaX / dtSeconds;
    _trackpadPanVelocityX = _trackpadPanVelocityX == 0
        ? instant
        : _trackpadPanVelocityX + (instant - _trackpadPanVelocityX) * 0.45;
  }

  void _startTrackpadPanMomentum(Velocity velocity) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position is ScrollPositionWithSingleContext) {
      // Gesture velocity is finger/focal velocity. Scroll position
      // velocity is the inverse: fingers moving left increase offset.
      final gestureVelocityX = -velocity.pixelsPerSecond.dx;
      final releaseVelocityX =
          gestureVelocityX.abs() >= _trackpadPanVelocityX.abs()
          ? gestureVelocityX
          : _trackpadPanVelocityX;
      position.goBallistic(releaseVelocityX);
    }
  }

  void _resetTapSeekTracking() {
    _tapSeekPointer = null;
    _tapSeekDownLocal = null;
    _tapSeekMoved = false;
    _tapSeekBlocked = false;
  }

  bool _isPrimaryTapSeekPointer(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      return event.buttons == 0 || (event.buttons & kPrimaryMouseButton) != 0;
    }
    return true;
  }

  void _onTapSeekPointerDown(PointerDownEvent event) {
    if (!_isPrimaryTapSeekPointer(event)) return;
    if (_tapSeekPointer != null) {
      _tapSeekBlocked = true;
      return;
    }
    _tapSeekPointer = event.pointer;
    _tapSeekDownLocal = event.localPosition;
    _tapSeekMoved = false;
    _tapSeekBlocked = false;
  }

  void _onTapSeekPointerMove(PointerMoveEvent event) {
    if (event.pointer != _tapSeekPointer) return;
    final down = _tapSeekDownLocal;
    if (down == null) return;
    if ((event.localPosition - down).distance > _kTapSeekSlop) {
      _tapSeekMoved = true;
    }
  }

  void _onTapSeekPointerUp(PointerUpEvent event) {
    if (event.pointer != _tapSeekPointer) return;
    final laneTop = _keystrokeLaneTopY;
    final inKeystrokeLane =
        laneTop != null && event.localPosition.dy >= laneTop;
    final shouldSeek =
        !_tapSeekBlocked &&
        !_tapSeekMoved &&
        !_pinchHasScaled &&
        !_trackpadPanActive &&
        !_trimDragging &&
        !inKeystrokeLane &&
        event.localPosition.dy >= rulerHeight;
    final x = event.localPosition.dx;
    _resetTapSeekTracking();
    if (shouldSeek) _seekFromTimelineViewportX(x);
  }

  void _onTapSeekPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _tapSeekPointer) _resetTapSeekTracking();
  }

  void _seekFromTimelineViewportX(double viewportX) {
    final viewport = _lastViewportWidth;
    if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final contentWidthPx = _timeAxisContentWidth(
      viewport,
      widget.timelineScale,
    );
    final contentX = (viewportX + offset - _scrollLeftInset)
        .clamp(0.0, contentWidthPx)
        .toDouble();
    final pps = _timeAxisPps(viewport, widget.duration, widget.timelineScale);
    widget.onSeek(xToTime(contentX, pps));
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
      _timeAxisViewport(width),
      widget.timelineScale,
      padPx: _scrollLeftInset,
    );
    if (_hoverProgress != progress) {
      setState(() => _hoverProgress = progress);
    }
    // Two-finger trackpad scroll at scale > 1 makes Flutter re-dispatch
    // onHover events as the content shifts under a stationary cursor,
    // even though the cursor's global position is unchanged. Treat that
    // as a scroll (not a scrub) — only call onHoverSeek when the global
    // pointer position actually moved.
    final didPointerMove =
        global == null ||
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
    // Match the build's `rulerToLaneGap` (intentionally tighter than
    // `laneSpacing`) so the cut-mode proximity zone aligns with the
    // visible lane top.
    const rulerToLaneGap = 0.0;
    final laneTop = rulerHeight + rulerToLaneGap + CutMarker.kHitHeight;
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
    final wantLane = _keystrokeLaneWanted(widget);
    if (wantLane != _keystrokeLaneWanted(old)) {
      if (wantLane) {
        _laneRevealCtl.forward();
      } else {
        _laneRevealCtl.reverse();
      }
    }
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
      // Apply the new scroll offset SYNCHRONOUSLY so the next paint
      // sees the new scale AND the new offset together. Previously this
      // was deferred to a post-frame callback ("so LayoutBuilder has
      // run before we jumpTo"), but that defer caused a 1-frame anchor
      // desync at every slider tick / pinch update: frame N+1 painted
      // with the new pps but the OLD scroll offset, then the post-frame
      // callback corrected it on frame N+2 — visible as a continuous
      // back-and-forth jitter during a drag.
      //
      // The defer is unnecessary: jumpTo just sets position.pixels (no
      // bounds clamp at call time — clamping happens in the next
      // layout's applyContentDimensions). And [_applyScale] already
      // pre-clamps via contentWidth(viewport, newScale), which is a
      // pure function — it doesn't need the new layout to have run.
      // [_lastViewportWidth] is captured in the previous build's
      // LayoutBuilder and is stable across consecutive rebuilds of
      // the same widget.
      _applyScale(
        old.timelineScale,
        widget.timelineScale,
        widget.pendingScaleAnchor,
      );
    }

    if (!identical(widget.position, old.position)) {
      // Caller swapped the listenable instance (rare in production but
      // common in widget tests that pump a fresh widget with each
      // position). Re-subscribe AND fire one auto-follow check against
      // the new value so behaviour matches a value-change notification.
      old.position.removeListener(_onPositionTick);
      widget.position.addListener(_onPositionTick);
      _onPositionTick();
    }
    // When the user trims mid-drag the clip list changes — re-anchor
    // the right-edge band to the viewport. Deferred to post-frame so
    // the layout has been measured with the new clips before we
    // jumpTo. No-op unless a right-edge drag is in flight + the
    // bloom is complete (see [_adjustScrollDuringRightDrag]).
    if (_activeEdgeSide == TrimSide.right) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _adjustScrollDuringRightDrag();
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

    final pps = _timeAxisPps(viewport, widget.duration, widget.timelineScale);
    final playheadContentX = timeToX(playhead, pps);
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    // Timeline content sits inside the scrollable canvas at
    // _scrollLeftInset, so playhead viewport-x must include it. The
    // right inset only affects maxOffset.
    final leftPad = _scrollLeftInset;
    final playheadViewportX = playheadContentX + leftPad - offset;

    if (playheadViewportX > 0.8 * viewport || playheadViewportX < 0) {
      final targetOffset = playheadContentX + leftPad - 0.2 * viewport;
      final maxOffset = _maxScrollOffset(viewport, widget.timelineScale);
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

  /// VSYNC tick driving pinch-scale smoothing. Advances [_renderScale]
  /// toward [_rawTargetScale] by a time-based EMA (coefficient derived
  /// from the real frame interval so it's frame-rate independent), then
  /// applies it via [onPinchScale] — at most once per frame. Skips the
  /// apply on steady holds (nothing changing) and stops once a release
  /// has settled onto the target.
  void _onPinchTick(Duration elapsed) {
    final dt = elapsed - _lastPinchElapsed;
    _lastPinchElapsed = elapsed;
    // Clamp dt so a stalled frame (GC pause, window drag) can't make
    // α≈1 and snap the scale in a single jump.
    final dtMs = (dt.inMicroseconds / 1000.0).clamp(1.0, 100.0);
    const tauMs = 55.0;
    final target = _rawTargetScale ?? _renderScale;
    final alpha = 1.0 - math.exp(-dtMs / tauMs);
    final newRender = (_renderScale + (target - _renderScale) * alpha).clamp(
      1.0,
      8.0,
    );
    final delta = (newRender - _renderScale).abs();
    _renderScale = newRender;

    final settled = delta < 0.0005 && (target - _renderScale).abs() < 0.0005;
    if (_pinchReleasing && settled) {
      _finishPinch();
      return;
    }
    // Steady hold (fingers still, not releasing): nothing to apply.
    if (!_pinchReleasing && settled) return;

    final anchor = _pinchAnchorTime ?? widget.position.value;
    widget.onPinchScale?.call(_renderScale, anchor);
  }

  /// Tear down all pinch state and stop the ticker. Called when a
  /// release has settled, or immediately for a gesture that never
  /// became a pinch.
  void _finishPinch() {
    _pinchTicker?.stop();
    _pinchReleasing = false;
    _pinchStartScale = null;
    _pinchAnchorTime = null;
    _pinchAnchorViewportX = null;
    _pinchHasScaled = false;
    _trackpadPanActive = false;
    _trackpadPanVelocityX = 0.0;
    _lastTrackpadPanTime = null;
    _rawTargetScale = null;
  }

  void _applyScale(double oldScale, double newScale, Duration? anchor) {
    final viewport = _lastViewportWidth;
    if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;
    final anchorTime = anchor ?? widget.position.value;

    final oldPps = _timeAxisPps(viewport, widget.duration, oldScale);
    final newPps = _timeAxisPps(viewport, widget.duration, newScale);
    final oldOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    // During an active pinch, override `anchorViewportX` with the
    // CURRENT focal-x (updated by onScaleUpdate every frame). The
    // default derivation includes the timeline's inner scroll inset
    // so it maps from content-x to actual viewport-x. Using the
    // gesture-tracking x keeps the anchor TIME
    // under the user's fingers as they naturally shift during the
    // pinch — a previous version of this code locked anchorVx at
    // gesture-start, which corrected the content back toward the
    // start point and felt like the timeline fighting the user.
    final contentLeft = _scrollLeftInset;
    final pinchVx = _pinchAnchorViewportX;
    final inPinch = pinchVx != null && anchor == _pinchAnchorTime;
    final anchorViewportX = inPinch
        ? pinchVx
        : contentLeft + timeToX(anchorTime, oldPps) - oldOffset;
    final newAnchorContentX = timeToX(anchorTime, newPps);
    final newOffset = contentLeft + newAnchorContentX - anchorViewportX;

    final maxOffset = _maxScrollOffset(viewport, newScale);
    final clamped = newOffset.clamp(0.0, maxOffset);

    if (_scrollController.hasClients) {
      // Guard with the programmatic flag so the scroll listener doesn't
      // mistake an anchor-preserve jump for a user-initiated scroll.
      _programmaticScrollInProgress = true;
      try {
        // `jumpTo` immediately starts a ballistic settle against the
        // *current* scroll extents. During a scale rebuild those extents
        // can still be from the old content width, so the settle briefly
        // fights the freshly computed anchor offset and the slices drift
        // until layout catches up. We already clamp against the new
        // mathematically-known extent above, so skip that settle here.
        // ignore: deprecated_member_use
        _scrollController.position.jumpToWithoutSettling(clamped);
      } finally {
        _programmaticScrollInProgress = false;
      }
    }

    if (anchor != null) {
      // Defer the anchor-clear to a microtask. The scroll jumpTo above
      // runs sync (required for smooth scaling — see the comment in
      // didUpdateWidget), but [onAnchorConsumed] flips a Riverpod
      // provider, which throws "Tried to modify a provider while the
      // widget tree was building" if invoked during didUpdateWidget.
      // The microtask runs after the current build pass settles, so
      // by then the tree-locked guard is released.
      scheduleMicrotask(() {
        if (mounted) widget.onAnchorConsumed?.call();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _cutCursorY.removeListener(_onCutCursorYChanged);
    widget.position.removeListener(_onPositionTick);
    _padCtlRight.removeListener(_onEdgePadTick);
    _padCtlRight.removeStatusListener(_onPadCtlRightStatus);
    _padCtlLeft.removeStatusListener(_onPadCtlLeftStatus);
    _padCtlLeft.dispose();
    _padCtlRight.dispose();
    _laneFloat.dispose();
    _lanePin.dispose();
    _laneRevealCtl.removeListener(_onLaneRevealTick);
    _laneRevealCtl.dispose();
    _pinchTicker?.dispose();
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
      for (final r
          in ref
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
    final controller = ref.read(editorProjectControllerProvider.notifier);
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
        final pps = _timeAxisPps(width, widget.duration, widget.timelineScale);
        final cw = _timeAxisContentWidth(width, widget.timelineScale);
        final animateTimelineLayout = !_pinchHasScaled && !_pinchReleasing;
        // Refresh the band-target snapshots so the live edge pad
        // (= bloomCtl.value * target) tracks the user's ongoing trim.
        // The first/last slice's outer trim in source-time gets
        // converted to edited pixels — same math SliceBar uses for
        // its own dim band, so the two stay in sync without an
        // explicit cross-widget notification.
        _bandLeftTargetPx = _ghostPxForFirstSlice(pps);
        _bandRightTargetPx = _ghostPxForLastSlice(pps);
        // Zoom lane is always rendered, even when empty, so users can
        // hover/click an empty patch to add a new zoom.
        final zoomLaneHeight = laneHeight + zoomBadgeAreaHeight;
        // The ruler-to-cut-marker gap is tighter than `laneSpacing`
        // (see the inline comment in the build tree below) so the
        // dot row hugs the clip lane.
        const rulerToLaneGap = 0.0;
        // Shortcuts timeline lane sits below the zoom lane and animates in/out
        // via _laneReveal (0 = collapsed, 1 = fully shown).
        final laneT = _laneReveal.value.clamp(0.0, 1.0);
        final laneBlockHeight = laneSpacing + keystrokeLaneHeight;
        final keystrokeLaneExtent = laneBlockHeight * laneT;
        final showKeystrokeLane =
            laneT > 0.001 && widget.keystrokeRecording != null;
        // Cache the lane block's top y so tap-seek can ignore taps that land
        // on a bar (those toggle the bar instead of seeking).
        _keystrokeLaneTopY = showKeystrokeLane
            ? rulerHeight +
                rulerToLaneGap +
                CutMarker.kHitHeight +
                laneHeight +
                laneSpacing +
                zoomLaneHeight
            : null;
        final totalHeight =
            rulerHeight +
            rulerToLaneGap +
            CutMarker.kHitHeight +
            laneHeight +
            laneSpacing +
            zoomLaneHeight +
            laneSpacing +
            zoomLaneHeight +
            keystrokeLaneExtent;

        return SizedBox(
          height: totalHeight,
          width: width,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onTapSeekPointerDown,
            onPointerMove: _onTapSeekPointerMove,
            onPointerUp: _onTapSeekPointerUp,
            onPointerCancel: _onTapSeekPointerCancel,
            child: GestureDetector(
              // Trackpad pinch → zoom the timeline anchored at the cursor.
              // `translucent` so single-finger taps/drags still reach the
              // lane gesture detectors underneath; we only consume events
              // once a true two-finger pinch is recognized.
              behavior: HitTestBehavior.translucent,
              onScaleStart: (d) {
                _stopScrollActivity();
                _trackpadPanActive = false;
                _trackpadPanVelocityX = 0.0;
                _lastTrackpadPanTime = null;
                _pinchStartScale = widget.timelineScale;
                _pinchHasScaled = false;
                _pinchReleasing = false;
                // Seed the smoothing state to the current scale. The
                // ticker (started on the first real pinch frame) advances
                // _renderScale toward _rawTargetScale from here.
                _renderScale = widget.timelineScale;
                _rawTargetScale = widget.timelineScale;
                // Seed the anchor-x to the gesture-start focal. It is
                // updated on pinch frames; the semantic anchor time stays
                // fixed.
                _pinchAnchorViewportX = d.localFocalPoint.dx;
                final viewport = _lastViewportWidth;
                if (viewport <= 0) {
                  _pinchAnchorTime = widget.position.value;
                  return;
                }
                final offset = _scrollController.hasClients
                    ? _scrollController.offset
                    : 0.0;
                final pps = _timeAxisPps(
                  viewport,
                  widget.duration,
                  widget.timelineScale,
                );
                final contentWidthPx = _timeAxisContentWidth(
                  viewport,
                  widget.timelineScale,
                );
                final anchorContentX =
                    (d.localFocalPoint.dx + offset - _scrollLeftInset)
                        .clamp(0.0, contentWidthPx)
                        .toDouble();
                _pinchAnchorTime = xToTime(anchorContentX, pps);
              },
              onScaleUpdate: (d) {
                // One-finger drags belong to the lane handlers; let
                // them through.
                if (d.pointerCount < 2) return;

                // Trackpad gestures arrive here with TWO components in
                // every update: a scale factor (pinch) AND a focal-point
                // delta (pan). We classify each frame as one or the
                // other, with a STICKY pinch mode:
                //
                //   * Pinch (|d.scale − 1| > ε): apply scale, anchored
                //     to the CURRENT focal-x so the time under the
                //     fingers stays under the fingers as they drift.
                //     Anchor TIME is still locked (no feedback loop).
                //
                //   * Pan (d.scale ≈ 1, AND we haven't entered pinch
                //     mode this gesture): scroll the timeline by the
                //     focal-delta. [_NoTrackpadScrollBehavior] has
                //     unhooked the Scrollable from trackpad events, so
                //     if we don't scroll here, nothing else will.
                //
                // Once any frame this gesture has been a pinch,
                // [_pinchHasScaled] suppresses the pan path for the
                // rest of the gesture. Without that flag, noisy scale
                // streams (1.003 → 1.001 → 1.004 → …) would briefly
                // dip into "pan" each time scale crossed back under
                // threshold, and the timeline would visibly twitch
                // sideways mid-pinch.
                const scaleEps = 0.002;
                final isPinch = (d.scale - 1.0).abs() > scaleEps;
                if (isPinch) {
                  _trackpadPanActive = false;
                  final start = _pinchStartScale ?? widget.timelineScale;
                  final rawNext = (start * d.scale).clamp(1.0, 8.0);
                  // Record the latest raw target. The actual scale is
                  // applied by [_onPinchTick] at vsync, NOT here — input
                  // events and frames don't align 1:1, so applying at
                  // event time resamples the motion unevenly (measured as
                  // a regular every-other-frame velocity alternation).
                  _rawTargetScale = rawNext;
                  final focalX = d.localFocalPoint.dx;
                  _pinchAnchorViewportX = focalX;
                  final firstPinchFrame = !_pinchHasScaled;
                  if (firstPinchFrame) {
                    // First pinch frame this gesture: lock the semantic
                    // anchor time to the focal where the pinch actually
                    // began. Later frames may move the viewport pivot x
                    // with the user's fingers, but this time anchor stays
                    // fixed so centroid drift cannot become time drift.
                    _pinchHasScaled = true;
                    final viewport = _lastViewportWidth;
                    if (viewport > 0) {
                      final offset = _scrollController.hasClients
                          ? _scrollController.offset
                          : 0.0;
                      final pps = _timeAxisPps(
                        viewport,
                        widget.duration,
                        widget.timelineScale,
                      );
                      final contentWidthPx = _timeAxisContentWidth(
                        viewport,
                        widget.timelineScale,
                      );
                      final anchorContentX =
                          (focalX + offset - _scrollLeftInset)
                              .clamp(0.0, contentWidthPx)
                              .toDouble();
                      _pinchAnchorTime = xToTime(anchorContentX, pps);
                    }
                    // Start the vsync ticker that drives smoothing. Reset
                    // the elapsed baseline so the first tick's dt is sane.
                    _lastPinchElapsed = Duration.zero;
                    _pinchTicker ??= createTicker(_onPinchTick);
                    if (_pinchTicker!.isActive) _pinchTicker!.stop();
                    _pinchTicker!.start();
                  }
                  // NOTE: no onPinchScale call here — _onPinchTick owns
                  // application so render cadence stays vsync-locked. The
                  // pivot x and raw target are sampled from input; the
                  // actual scale/scroll application stays vsync-locked.
                } else if (!_pinchHasScaled) {
                  // Pure two-finger pan, gesture hasn't become a pinch
                  // yet → scroll the timeline.
                  final dx = d.focalPointDelta.dx;
                  if (dx != 0) {
                    _trackpadPanActive = true;
                    _recordTrackpadPanVelocity(dx, d.sourceTimeStamp);
                    _applyTrackpadPan(dx);
                  }
                }
                // Sub-eps frames once we're in pinch mode: do nothing.
                // The next supra-eps pinch frame resumes scale updates.
              },
              onScaleEnd: (d) {
                // If a pinch happened, let the ticker keep running and
                // settle _renderScale onto the final target (a smooth
                // landing, not a snap), then tear down in _finishPinch.
                // For a gesture that never became a pinch (pure pan /
                // tap), there's no ticker to settle — clean up now.
                if (_pinchHasScaled &&
                    _pinchTicker != null &&
                    _pinchTicker!.isActive) {
                  _pinchReleasing = true;
                } else {
                  if (_trackpadPanActive) {
                    _startTrackpadPanMomentum(d.velocity);
                  }
                  _finishPinch();
                }
              },
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
                child: ScrollConfiguration(
                  // See [_NoTrackpadScrollBehavior] — the Scrollable does
                  // not see trackpad events. Our top-level scale handler
                  // owns them.
                  behavior: const _NoTrackpadScrollBehavior(),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    // The scroll canvas owns the edge insets, so the
                    // viewport clips one coherent scroll surface rather
                    // than content wrapped in outside padding.
                    physics: const BouncingScrollPhysics(
                      decelerationRate: ScrollDecelerationRate.fast,
                      parent: RangeMaintainingScrollPhysics(),
                    ),
                    // Scoped rebuild: only the scroll canvas width/content
                    // offset recompute per tick; the inner content Stack
                    // and all lanes are passed as `child` and reused
                    // across the animation. Without this, every vsync of
                    // _padCtl would rebuild ClipLane (one SliceBar per
                    // clip) + ZoomLane + TimeRuler.
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_padCtlLeft, _padCtlRight]),
                      builder: (context, child) {
                        final leftInset = _scrollLeftInset;
                        return SizedBox(
                          width: cw + leftInset + _scrollRightInset,
                          height: totalHeight,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                left: leftInset,
                                top: 0,
                                width: cw,
                                height: totalHeight,
                                child: child!,
                              ),
                            ],
                          ),
                        );
                      },
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
                                // No gap between ruler and cut-marker strip —
                                // the ruler's dot row sits flush with the
                                // marker strip so labels read as "above THIS
                                // lane" rather than floating in their own
                                // strip. The bulk of the visual gap to the
                                // clip lane comes from CutMarker.kHitHeight,
                                // which is needed for marker pins.
                                SizedBox(
                                  height: CutMarker.kHitHeight,
                                  child: CutMarkerStrip(
                                    clips: widget.clips,
                                    pixelsPerSecond: pps,
                                    onClearSeamTrims: (i) =>
                                        widget.onClearSeamTrims?.call(i),
                                    onMergeSeam: (i) =>
                                        widget.onMergeSeam?.call(i),
                                    onClearStartTrim: () =>
                                        widget.onClearStartTrim?.call(),
                                    onClearEndTrim: () =>
                                        widget.onClearEndTrim?.call(),
                                    dragging: _trimDragging,
                                    activeDrag: _activeTrimDrag,
                                    animateLayout: animateTimelineLayout,
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
                                        animation: Listenable.merge([
                                          _laneFloat,
                                          _lanePin,
                                        ]),
                                        builder: (context, child) {
                                          final floatDy =
                                              math.sin(
                                                _laneFloat.value * 2 * math.pi,
                                              ) *
                                              2.0;
                                          final pinT = Curves.easeOutCubic
                                              .transform(_lanePin.value);
                                          final dy =
                                              floatDy * (1 - pinT) +
                                              _kPinDy * pinT;
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
                                          onTrimDragChanged: _setTrimDragging,
                                          animateLayout: animateTimelineLayout,
                                        ),
                                      ),
                                      if (widget.cutModeActive)
                                        Positioned.fill(
                                          child: CutOverlay(
                                            pixelsPerSecond: pps,
                                            totalEditedDuration:
                                                widget.duration,
                                            cursorX: _cutCursorX,
                                            // The scissors tool is sticky — a single
                                            // tap commits one cut and the overlay
                                            // stays armed so the user can keep
                                            // slicing without re-engaging the
                                            // toolbar. Esc (or toggling the toolbar
                                            // button again) exits.
                                            onCommitCut:
                                                (
                                                  editedTime, {
                                                  required bool overrideSnap,
                                                }) {
                                                  _attemptSplit(
                                                    editedTime,
                                                    overrideSnap: overrideSnap,
                                                  );
                                                },
                                            onExitMode: () => widget
                                                .onCutModeChanged
                                                ?.call(false),
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
                                      trimDragging: _trimDragging,
                                      animateLayout: animateTimelineLayout,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: laneSpacing),
                                SizedBox(
                                  height: zoomLaneHeight,
                                  child: CameraLane(
                                    duration: widget.duration,
                                    pixelsPerSecond: pps,
                                    contentWidth: cw,
                                    cameraRegions: widget.cameraRegions,
                                    clips: widget.clips,
                                    selectedIndex: widget.selectedCameraIndex,
                                    onCameraChanged: widget.onCameraChanged,
                                    onCameraSelected: widget.onCameraSelected,
                                    onCameraDeleted: widget.onCameraDeleted,
                                    onCameraAdded: widget.onCameraAdded,
                                    onSeek: widget.onSeek,
                                    trimDragging: _trimDragging,
                                    animateLayout: animateTimelineLayout,
                                  ),
                                ),
                                if (showKeystrokeLane)
                                  ClipRect(
                                    child: Align(
                                      alignment: Alignment.topCenter,
                                      heightFactor: laneT,
                                      child: Opacity(
                                        opacity: laneT,
                                        child: SizedBox(
                                          height: laneBlockHeight,
                                          child: Column(
                                            children: [
                                              const SizedBox(
                                                  height: laneSpacing),
                                              SizedBox(
                                                height: keystrokeLaneHeight,
                                                child: KeystrokeTimelineLane(
                                                  recording:
                                                      widget.keystrokeRecording!,
                                                  settings:
                                                      widget.keystrokeSettings,
                                                  clips: widget.clips,
                                                  pixelsPerSecond: pps,
                                                  contentWidth: cw,
                                                  onToggle:
                                                      widget.onKeystrokeToggle,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
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
                                  // Per-vsync ticks land here and only here:
                                  // ValueListenableBuilder rebuilds the
                                  // CustomPaint, the RepaintBoundary keeps the
                                  // playhead on its own layer, and PlayheadPainter
                                  // already shouldRepaints on progress change.
                                  child: ValueListenableBuilder<Duration>(
                                    valueListenable: widget.position,
                                    builder: (context, position, _) {
                                      return CustomPaint(
                                        size: Size(cw, totalHeight),
                                        painter: PlayheadPainter(
                                          progress:
                                              widget.duration.inMicroseconds ==
                                                  0
                                              ? 0
                                              : (position.inMicroseconds /
                                                        widget
                                                            .duration
                                                            .inMicroseconds)
                                                    .clamp(0.0, 1.0),
                                          hoverProgress: widget.isPlaying
                                              ? null
                                              : _hoverProgress,
                                          rulerHeight: rulerHeight,
                                          flashOn: widget.playheadFlashOn,
                                        ),
                                      );
                                    },
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
              ),
            ),
          ),
        );
      },
    );
  }
}
