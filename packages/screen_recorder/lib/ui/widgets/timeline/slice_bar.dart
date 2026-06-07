import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Which handle of a slice is being dragged. Bubbled out of
/// [SliceBar.onTrimDragChanged] so the parent timeline can react
/// asymmetrically (e.g. expand only the LEFT edge pad when the very
/// first slice's LEFT handle is the one being trimmed).
enum TrimSide { left, right }

/// Payload for [SliceBar.onTrimDragChanged]. A non-null instance
/// signals "drag started"; null signals "drag ended/cancelled". The
/// sliceIndex is the lane-level index passed into [SliceBar].
class TrimDragInfo {
  const TrimDragInfo({required this.sliceIndex, required this.side});
  final int sliceIndex;
  final TrimSide side;
}

/// One slice's rendering on the clip lane. Handles its own trim drags,
/// selection toggle, chevron-notch visibility on trimmed sides, and
/// the pulsing outer glow when selected.
class SliceBar extends StatefulWidget {
  const SliceBar({
    super.key,
    required this.slice,
    required this.sliceIndex,
    required this.isSelected,
    required this.pixelsPerSecond,
    required this.editedStart,
    required this.onSelectionToggle,
    required this.onTrimStartChanged,
    required this.onTrimEndChanged,
    this.onTrimDragChanged,
    this.animateLayout = true,
  });

  final ClipSlice slice;
  final int sliceIndex;
  final bool isSelected;
  final double pixelsPerSecond;
  final Duration editedStart;
  final ValueChanged<int> onSelectionToggle;
  final ValueChanged<Duration> onTrimStartChanged;
  final ValueChanged<Duration> onTrimEndChanged;
  // Fires at the start (non-null payload) and end (null) of either
  // trim handle's drag. Lets the parent ClipLane reorder this slice
  // to the top of the Stack and dim its siblings for the duration of
  // the drag, AND lets the timeline above react asymmetrically to
  // edge-handle drags — only the first slice's LEFT handle (or the
  // last slice's RIGHT handle) can push the dim band off the viewport
  // edge, so only those drags need the timeline-edge pad to expand.
  final ValueChanged<TrimDragInfo?>? onTrimDragChanged;
  final bool animateLayout;

  @override
  State<SliceBar> createState() => _SliceBarState();
}

class _SliceBarState extends State<SliceBar> with TickerProviderStateMixin {
  // Anchors capture both the trim Duration AND the gesture's starting
  // global x at drag-start. Computing each update against the start
  // position (rather than accumulating frame-by-frame deltas) avoids
  // losing the pre-slop pixels that the gesture arena consumes before
  // the first update fires.
  Duration? _trimStartAnchor;
  Duration? _trimEndAnchor;
  double? _dragStartGlobalX;
  // Which handle is currently driving the bloom — gates which dim
  // band renders. Set when a drag starts, intentionally NOT cleared
  // on drag end: the bloom reverses to t=0 over [_expandDuration],
  // and the band stays gated to the just-dragged side while it fades
  // out. The next drag overwrites it. nullable so the very first
  // build (before any drag has fired) renders neither band.
  TrimSide? _draggingSide;

  // Continuous gentle pulse on the selected-slice's offset stroke
  // ring. Slow + narrow-alpha-range so the ring feels alive but not
  // distracting. The controller is created on demand the first time
  // isSelected flips true (most slices never enter the selected state).
  AnimationController? _glow;
  static const Duration _glowPeriod = Duration(milliseconds: 2000);

  // Hover state controls the per-edge drag-affordance pills. We track
  // it locally instead of routing through ClipLane because nothing
  // outside this widget needs to know about hover (the neighbour
  // halo is driven off selection, not hover).
  bool _hovered = false;

  // ── Style constants (all the layout/timing knobs in one block at the
  // top so each builder reads as "what" rather than "what plus a magic
  // number"). Grouped by visual element below.

  // Selection ring: sits OUTSIDE the body's bounds with a 3px transparent
  // gap so the halo reads as a frame, not an outline. Corner radius is
  // body radius + inset so the ring concentrically tracks the body's
  // rounded corners.
  static const double _kRingInset = 3.0;
  static const double _kRingStroke = 1.5;
  static const double _kRingRadius = 11.0;

  // Hover-affordance pill: a thin vertical rounded rect at each
  // body edge, fading in 150ms when the cursor enters the slice.
  // Hidden on a side that's already trimmed — the chevron is doing
  // the "drag to restore" job there and two cues would fight.
  static const double _kHandlePillWidth = 3.0;
  static const double _kHandlePillHeight = 18.0;
  static const double _kHandleSlotPx = 8.0;
  // Distance from the body's edge to the pill — gives the pill some
  // visual breathing room instead of sitting flush against the corner.
  static const double _kHandleEdgeInset = 6.0;
  // Below this body width the two pills would crowd each other (each
  // sits 6px in from its edge with a 3px stroke, so the math floor is
  // ~18px; we add slack so they look intentionally spaced, not just
  // technically non-overlapping). Below the floor we suppress them.
  static const double _kHandleMinBodyPx = 32.0;
  static const Duration _kHoverFade = Duration(milliseconds: 150);

  // Slice label / inner caption transition timing — gentle fade+slide
  // when the slice width crosses the visibility thresholds during a
  // trim drag.
  static const Duration _kLabelFadeDuration = Duration(milliseconds: 200);

  // Expand animation: drives the "bloom" effect during a trim drag.
  // t=0 → just the active body (current behaviour). t=1 → body extends
  // to the full cutSpan with dim bands covering the trimmed-away source
  // on each side, plus a slight uniform scale-up so the slice appears
  // lifted above its dimmed siblings. Triggered by drag start/end, NOT
  // by selection — selection on its own keeps the regular white-border
  // + pulsing-glow highlight.
  late final AnimationController _expand;
  late final Animation<double> _expandT;
  static const Duration _expandDuration = Duration(milliseconds: 220);
  static const double _liftScale = 0.04;

  // Width-change animation. Without this the slice's body snaps to its
  // new edited-length width whenever a non-drag source mutates the
  // clip — restoring a trim (cut-marker tap), merging two slices, or
  // a parent-driven scale/duration change. We lerp the RENDERED width
  // from its current value to the new target over [_widthAnimDuration]
  // so the user sees a smooth grow/shrink instead of a discontinuous
  // jump.
  //
  // During a TRIM DRAG we bypass the animation and snap, because the
  // body must track the cursor in real time — interpolation there
  // would feel like the body is dragging behind the user.
  late final AnimationController _widthCtl;
  late Animation<double> _widthAnim;
  late double _renderWidthPx;
  static const Duration _widthAnimDuration = Duration(milliseconds: 220);

  // The dim trim bands render as SIBLINGS of the bright body, painted
  // BEHIND it in z-order and extended by [_kDimCornerRadius] past the
  // body's rounded edge so the body cleanly covers the dim's straight
  // inner edge. The dim shows through wherever the body's rounded
  // corner cuts away — visually the two read as one connected slice,
  // with the bright body's curve as the seam rather than a hard line.
  // Each dim band carries 8 px rounded corners on its OUTER edge (the
  // trimmed-away extreme), matching the body's own corner radius.
  static const double _kDimCornerRadius = 8.0;
  // Minimum width before a dim band renders. Sub-pixel widths just
  // shimmer at the start/end of the bloom; filtering them out is
  // visually quieter than animating in from 0px.
  static const double _kDimBandMinPx = 1.0;
  // Small white scissors icon centered in each dim band — same
  // metaphor as the cut tool elsewhere in the canvas, signalling
  // "this side is trimmed and will not play". Only shown when the
  // visible band is wider than the icon plus a comfort margin;
  // crosses the threshold smoothly via [AnimatedOpacity].
  static const double _kDimScissorsSize = 14.0;
  static const double _kDimScissorsMinBandPx = 24.0;
  static const Duration _kDimScissorsFitFade = Duration(milliseconds: 150);
  // 2 px gap between adjacent slice bodies so seams read as discrete
  // shapes instead of one continuous strip. Applied as a right-side
  // shrink on the body only — trim handles and dim bands still
  // measure from the true `_widthPx` seam position so gestures stay
  // pixel-accurate. The last slice's invisible trailing gap is benign.
  static const double _kInterSliceGap = 2.0;
  // Cap on how far a dim band visually extends past the body. Heavy
  // trims used to push the band's far edge off the viewport (and
  // sometimes past the screen edge). The cap keeps the scissors +
  // seconds label readable however far the user trims; the numeric
  // label inside the band still reflects the full trim amount.
  static const double _kDimMaxPx = 200.0;
  // Band-width threshold above which the seconds label renders next
  // to the scissors icon ("✂ 12.4s"). Below it, just the icon shows.
  static const double _kDimLabelMinBandPx = 52.0;

  // Subtle amber glow bar painted at the dim/bright divider — a thin
  // vertical line with a soft halo, vertically inset so it doesn't
  // clash with the rounded corners. Communicates "this is the trim
  // boundary you're dragging" without competing with the chevron or
  // the selection ring.
  static const double _kTrimDividerWidth = 2.0;
  static const double _kTrimDividerInset = 4.0;

  // Tick rhythm thresholds: ticks render once the body is at least
  // 48px wide; label slides in at 80px, caption at 140px.
  static const double _kTicksMinBodyPx = 48.0;
  static const double _kLabelMinBodyPx = 80.0;
  static const double _kCaptionMinBodyPx = 140.0;

  @override
  void initState() {
    super.initState();
    _expand = AnimationController(
      vsync: this,
      duration: _expandDuration,
      value: 0.0,
    );
    _expandT = CurvedAnimation(parent: _expand, curve: Curves.easeOutCubic);
    _renderWidthPx = _targetWidthPx;
    _widthCtl = AnimationController(vsync: this, duration: _widthAnimDuration)
      ..addListener(_onWidthTick);
    _widthAnim = AlwaysStoppedAnimation<double>(_renderWidthPx);
    if (widget.isSelected) _ensureGlowRunning();
  }

  @override
  void didUpdateWidget(covariant SliceBar old) {
    super.didUpdateWidget(old);
    if (widget.isSelected && !old.isSelected) {
      _ensureGlowRunning();
    } else if (!widget.isSelected && old.isSelected) {
      _glow?.stop();
      // Safety net: if the trim drag's end callback never fired (a
      // mid-drag parent rebuild can drop the gesture's end event), the
      // bloom would stay expanded and siblings would stay dimmed. When
      // selection moves elsewhere we force a clean reset.
      _maybeRecoverFromStuckDrag();
    }
    _maybeAnimateWidth();
  }

  /// Called whenever a fresh build reports a new [_targetWidthPx]. Two
  /// modes:
  ///   - trim drag / pinch zoom in flight: the body MUST track the
  ///     cursor frame by frame, so we snap [_renderWidthPx] to target
  ///     and kill any in-flight tween.
  ///   - any other source of change (cut-marker tap restoring a trim,
  ///     mergeSeam, parent scale, pps drift from a duration change):
  ///     tween from the current rendered width to the new target so
  ///     the slice grows / shrinks smoothly instead of jumping.
  void _maybeAnimateWidth() {
    final target = _targetWidthPx;
    if ((target - _renderWidthPx).abs() < 0.5) return;
    if (_dragInFlight || !widget.animateLayout) {
      _widthCtl.stop();
      _renderWidthPx = target;
      return;
    }
    _widthAnim = Tween<double>(
      begin: _renderWidthPx,
      end: target,
    ).animate(CurvedAnimation(parent: _widthCtl, curve: Curves.easeOutCubic));
    _widthCtl
      ..reset()
      ..forward();
  }

  void _onWidthTick() {
    if (!mounted) return;
    final v = _widthAnim.value;
    if ((v - _renderWidthPx).abs() < 0.1) return;
    setState(() => _renderWidthPx = v);
  }

  /// Scrolls the parent timeline so the cursor — the trim handle being
  /// dragged — never sits flush against the viewport edge. The cursor
  /// has [_kEdgeMargin] px of breathing room from each side; when the
  /// user pushes past that, we jumpTo by exactly enough to put it
  /// back. Net effect: the body + dim band slide with the mouse,
  /// giving the dim space to keep growing instead of clipping off-
  /// screen. Caller is the trim drag-update handler so the scroll
  /// follows the gesture in real time.
  static const double _kEdgeMargin = 64.0;
  void _followCursorAtViewportEdge(double cursorGlobalX) {
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    final position = scrollable.position;
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    final scrollableBox = scrollable.context.findRenderObject() as RenderBox?;
    if (scrollableBox == null) return;
    final viewportLeftGlobal = scrollableBox.localToGlobal(Offset.zero).dx;
    final viewportRightGlobal = viewportLeftGlobal + scrollableBox.size.width;
    double? deltaPx;
    if (cursorGlobalX < viewportLeftGlobal + _kEdgeMargin) {
      deltaPx = cursorGlobalX - (viewportLeftGlobal + _kEdgeMargin);
    } else if (cursorGlobalX > viewportRightGlobal - _kEdgeMargin) {
      deltaPx = cursorGlobalX - (viewportRightGlobal - _kEdgeMargin);
    }
    if (deltaPx == null) return;
    final target = (position.pixels + deltaPx).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() > 0.5) {
      position.jumpTo(target);
    }
  }

  // Distinct from [_draggingSide], which lingers across the
  // [_expand] reverse so the just-dragged band fades smoothly. This
  // flag is true ONLY while the gesture is in flight, so
  // [_maybeAnimateWidth] can snap during a drag and animate
  // afterwards.
  bool _dragInFlight = false;
  void _setDragging(bool dragging, {TrimSide? side}) {
    if (dragging) {
      assert(side != null, '_setDragging(true) requires side');
      _dragInFlight = true;
      _draggingSide = side;
      _expand.forward();
      widget.onTrimDragChanged?.call(
        TrimDragInfo(sliceIndex: widget.sliceIndex, side: side!),
      );
    } else {
      _dragInFlight = false;
      _expand.reverse();
      widget.onTrimDragChanged?.call(null);
    }
  }

  // True iff _expand is parked above 0 without animating — i.e., the
  // controller never received its reverse signal. Drives the safety
  // recovery in [_maybeRecoverFromStuckDrag] and the onTap fallback.
  bool get _expandIsStuck => _expand.value > 0 && !_expand.isAnimating;

  void _maybeRecoverFromStuckDrag() {
    if (!_expandIsStuck) return;
    _expand.value = 0;
    _dragInFlight = false;
    widget.onTrimDragChanged?.call(null);
  }

  void _ensureGlowRunning() {
    _glow ??= AnimationController(vsync: this, duration: _glowPeriod);
    if (!_glow!.isAnimating) {
      _glow!.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _glow?.dispose();
    _expand.dispose();
    _widthCtl.dispose();
    super.dispose();
  }

  // Trimmed-away duration on each side, converted to EDITED pixels
  // (source seconds / playbackSpeed * pps) — the same coordinate space
  // as the timeline. Drives the width of the dim bands on each side
  // when the slice is in expanded mode.
  double get _leftFullGhostPx =>
      _ghostPxFor(widget.slice.trimStart - widget.slice.cutStart);
  double get _rightFullGhostPx =>
      _ghostPxFor(widget.slice.cutEnd - widget.slice.trimEnd);
  double _ghostPxFor(Duration sourceDelta) {
    if (sourceDelta <= Duration.zero) return 0;
    final speed = widget.slice.playbackSpeed > 0
        ? widget.slice.playbackSpeed
        : 1.0;
    return sourceDelta.inMilliseconds / 1000.0 / speed * widget.pixelsPerSecond;
  }

  // The slice is rendered in EDITED time on the timeline, so 1 pixel
  // corresponds to `1 / pixelsPerSecond` edited seconds. The underlying
  // trim bounds live in SOURCE time, so converting a pixel delta back to
  // a trim delta multiplies by playbackSpeed (1 edited-second of drag =
  // `speed` source-seconds of trim movement at the slice's speed).
  //
  // Target = the literal current edited length × pps. Render = the
  // animated value used by all visual children; they lerp toward target
  // over [_widthAnimDuration] except during a trim drag (see
  // [_maybeAnimateWidth]).
  double get _targetWidthPx =>
      widget.slice.editedLength.inMilliseconds /
      1000.0 *
      widget.pixelsPerSecond;
  double get _widthPx => _renderWidthPx;
  double get _sourceSecondsPerPixel {
    if (widget.pixelsPerSecond <= 0) return 0;
    final speed = widget.slice.playbackSpeed > 0
        ? widget.slice.playbackSpeed
        : 1.0;
    return speed / widget.pixelsPerSecond;
  }

  void _onLeftDragStart(DragStartDetails d) {
    _trimStartAnchor = widget.slice.trimStart;
    _dragStartGlobalX = d.globalPosition.dx;
    _setDragging(true, side: TrimSide.left);
    _ensureSelected();
  }

  void _onLeftDragUpdate(DragUpdateDetails d) {
    final anchor = _trimStartAnchor;
    final startX = _dragStartGlobalX;
    if (anchor == null || startX == null) return;
    final deltaSec = (d.globalPosition.dx - startX) * _sourceSecondsPerPixel;
    final next = anchor + Duration(microseconds: (deltaSec * 1e6).round());
    widget.onTrimStartChanged(next);
    _followCursorAtViewportEdge(d.globalPosition.dx);
  }

  void _onLeftDragEnd(DragEndDetails _) => _setDragging(false);
  void _onLeftDragCancel() => _setDragging(false);
  // _setDragging(false) doesn't need the `side` arg — only "is dragging"
  // is meaningful at the end edge.

  void _onRightDragStart(DragStartDetails d) {
    _trimEndAnchor = widget.slice.trimEnd;
    _dragStartGlobalX = d.globalPosition.dx;
    _setDragging(true, side: TrimSide.right);
    _ensureSelected();
  }

  // Fired at every trim-drag-start. Selects the slice when it isn't
  // already — dragging a slice should treat that gesture as a
  // selection commit so the inspector swaps to the slice editor
  // without the user having to tap-first-then-drag.
  void _ensureSelected() {
    if (!widget.isSelected) {
      widget.onSelectionToggle(widget.sliceIndex);
    }
  }

  void _onRightDragUpdate(DragUpdateDetails d) {
    final anchor = _trimEndAnchor;
    final startX = _dragStartGlobalX;
    if (anchor == null || startX == null) return;
    final deltaSec = (d.globalPosition.dx - startX) * _sourceSecondsPerPixel;
    final next = anchor + Duration(microseconds: (deltaSec * 1e6).round());
    widget.onTrimEndChanged(next);
    _followCursorAtViewportEdge(d.globalPosition.dx);
  }

  void _onRightDragEnd(DragEndDetails _) => _setDragging(false);
  void _onRightDragCancel() => _setDragging(false);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _expand,
        _glow ?? const AlwaysStoppedAnimation<double>(0),
      ]),
      builder: (context, _) {
        final t = _expandT.value;
        final glowT = _glow?.value ?? 0.0;
        // Bands are capped at [_kDimMaxPx] so the scissors + label
        // inside them stay readable regardless of how much the user
        // trims. The parent timeline expands its own edge pad to fit
        // the capped band plus a small margin so the band never
        // overflows the viewport edge. Only the side currently being
        // dragged shows a band — _draggingSide lingers across the
        // [_expand] reverse so the just-dragged side fades out
        // smoothly.
        final side = _draggingSide;
        final bandLeft = side == TrimSide.left
            ? math.min(t * _leftFullGhostPx, _kDimMaxPx)
            : 0.0;
        final bandRight = side == TrimSide.right
            ? math.min(t * _rightFullGhostPx, _kDimMaxPx)
            : 0.0;
        // totalWidth tracks the SELECTION RING's footprint — body + dim
        // bands. Shrink the body term by the same inter-slice gap so
        // the ring hugs the visible body's right edge rather than
        // floating into the gap.
        final bodyWidthForRing = math.max(0.0, _widthPx - _kInterSliceGap);
        final totalWidth = bandLeft + bodyWidthForRing + bandRight;
        final isSel = widget.isSelected;
        // Slight uniform scale-up while selected so the lifted slice
        // looks bigger than its dimmed siblings. Anchored centre so
        // the active region stays visually pinned in place.
        return Transform.scale(
          scale: 1.0 + _liftScale * t,
          alignment: Alignment.center,
          child: MouseRegion(
            onEnter: (_) {
              if (!_hovered) setState(() => _hovered = true);
            },
            onExit: (_) {
              if (_hovered) setState(() => _hovered = false);
            },
            child: GestureDetector(
              onTap: () {
                _maybeRecoverFromStuckDrag();
                widget.onSelectionToggle(widget.sliceIndex);
              },
              child: SizedBox(
                // Layout slot stays at the active-region width — only the
                // visuals spill outside via Clip.none. This keeps adjacent
                // slices' tap targets reachable when the selected slice's
                // dim bands visually overlap them.
                width: _widthPx,
                height: laneHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  // ── Stack layers, painted bottom-to-top. Every Positioned
                  // child carries a ValueKey because the list grows/shrinks
                  // during a drag (dim bands appear/disappear when bandWidth
                  // crosses 0; chevrons disappear when isLeftTrimmed flips
                  // false at full-restore). Without keys, the position-based
                  // diff can mis-match the handle's Positioned to a different
                  // slot, blowing away the RawGestureDetectorState and
                  // dropping the in-flight pointer — which is what made
                  // onHorizontalDragEnd silently fail to fire.
                  children: [
                    // Dim bands paint FIRST (behind the body) and
                    // extend past the body's rounded edge so the body
                    // cleanly covers the band's straight inner side.
                    // Where the body's rounded corner cuts away, the
                    // dim shows through — the visible seam is the
                    // body's curve, not a hard line between them.
                    if (bandLeft > _kDimBandMinPx)
                      _buildLeftDimBand(bandLeft, t),
                    if (bandRight > _kDimBandMinPx)
                      _buildRightDimBand(bandRight, t),
                    // Scissors glyph centered in each band. Always
                    // mounted while the band is visible; the AnimatedOpacity
                    // inside fades the icon out smoothly when the band
                    // shrinks below the fit threshold mid-drag (no
                    // hard-cut between visible and hidden).
                    if (bandLeft > _kDimBandMinPx)
                      _buildLeftDimScissors(bandLeft, t),
                    if (bandRight > _kDimBandMinPx)
                      _buildRightDimScissors(bandRight, t),
                    _buildBody(isSel: isSel),
                    // Glow lines at the dim/bright seam — gated on the
                    // same band visibility so they only appear when a
                    // trimmed side has a non-trivial band to divide.
                    if (bandLeft > _kDimBandMinPx) _buildLeftTrimDivider(t),
                    if (bandRight > _kDimBandMinPx) _buildRightTrimDivider(t),
                    if (_widthPx >= _kTicksMinBodyPx) _buildTicks(),
                    _buildLabel(),
                    if (widget.slice.isLeftTrimmed && t < 1.0)
                      _buildLeftChevron(t),
                    if (widget.slice.isRightTrimmed && t < 1.0)
                      _buildRightChevron(t),
                    if (!widget.slice.isLeftTrimmed &&
                        _widthPx >= _kHandleMinBodyPx)
                      _buildLeftHoverPill(),
                    if (!widget.slice.isRightTrimmed &&
                        _widthPx >= _kHandleMinBodyPx)
                      _buildRightHoverPill(),
                    if (isSel)
                      _buildSelectionRing(
                        bandLeft: bandLeft,
                        totalWidth: totalWidth,
                        glowT: glowT,
                      ),
                    _buildLeftHandle(),
                    _buildRightHandle(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Stack-layer builders ────────────────────────────────────────────────
  // Each returns one Positioned. The order of calls in build()'s Stack
  // determines paint order. Keys must match the originals — tests pin to
  // `slice-bar-body`, `slice-bar-{left,right}-handle`, and
  // `slice-bar-{left,right}-chevron`; the other keys are essential for
  // Stack child-identity stability across the bloom transitions.

  /// Bright "lit" active region. Always sits at `[0, _widthPx]` with
  /// rounded 8 px corners on all four sides so the lit body itself
  /// carries the curve — during a trim drag the dim bands grow next
  /// to it as separate siblings, NOT as an overlay covering its
  /// rounded corners. That way the visible bright-vs-dim seam is
  /// shaped by the body's own rounded edge rather than by the dim
  /// overlay's cut-out.
  Widget _buildBody({required bool isSel}) {
    final bodyWidth = math.max(0.0, _widthPx - _kInterSliceGap);
    return Positioned(
      key: const ValueKey('slice-bar-body-pos'),
      left: 0,
      top: 0,
      width: bodyWidth,
      height: laneHeight,
      child: Container(
        key: const ValueKey('slice-bar-body'),
        decoration: BoxDecoration(
          // Vertical "lit from above" gradient — same hue family,
          // slightly brighter at the top and slightly darker at the
          // bottom, so the bar reads as a tactile surface instead of
          // a flat fill.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _bodyGradientColors(isSel ? clipFillTop : clipFill),
            stops: const [0.0, 0.55, 1.0],
          ),
          borderRadius: BorderRadius.circular(8),
          // The unselected stroke stays for the regular resting state;
          // the selected look is delivered by an OUTSIDE offset ring
          // (rendered later) so the body itself can drop the white
          // border.
          border: isSel ? null : Border.all(color: clipStroke, width: 1.0),
        ),
      ),
    );
  }

  /// Dim band over the left-trimmed source. Sits NEXT TO the bright
  /// body (not on top of it) — same lit-from-above gradient as the
  /// body, darkened in HSL space so it reads as a "ghost" of the
  /// active region rather than a neutral grey overlay. Outer corners
  /// rounded to match the body's 8 px radius; inner edge sits straight
  /// against the body's rounded left curve, so the visible seam is
  /// shaped by the body's rounded edge.
  Widget _buildLeftDimBand(double bandLeft, double t) {
    // Extend past the body's left edge by _kDimCornerRadius so the
    // body's rounded top-left + bottom-left corners cover the band's
    // straight inner edge cleanly — without the extension the body's
    // curved cutout would expose the slice's track-bg backdrop and
    // the band would visually disconnect from the body.
    return Positioned(
      key: const ValueKey('slice-bar-dim-left'),
      left: -bandLeft,
      top: 0,
      bottom: 0,
      width: bandLeft + _kDimCornerRadius,
      child: IgnorePointer(
        child: Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(_kDimCornerRadius),
              bottomLeft: Radius.circular(_kDimCornerRadius),
            ),
            child: _dimBandSurface(slopeLeft: true),
          ),
        ),
      ),
    );
  }

  Widget _buildRightDimBand(double bandRight, double t) {
    return Positioned(
      key: const ValueKey('slice-bar-dim-right'),
      left: _widthPx - _kDimCornerRadius,
      top: 0,
      bottom: 0,
      width: bandRight + _kDimCornerRadius,
      child: IgnorePointer(
        child: Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: ClipRRect(
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(_kDimCornerRadius),
              bottomRight: Radius.circular(_kDimCornerRadius),
            ),
            child: _dimBandSurface(slopeLeft: false),
          ),
        ),
      ),
    );
  }

  /// Surface of a dim band: 3-stop lit-from-above gradient (same as
  /// the body, dropped 42 lightness points in HSL) with a faint
  /// diagonal hatch overlay reinforcing "this side is removed". The
  /// hatch slope mirrors per side so the two bands lean toward each
  /// other across the bright body, reading as a single trim shape
  /// rather than two unrelated textures.
  Widget _dimBandSurface({required bool slopeLeft}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _dimGradientColors(clipFill),
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
        CustomPaint(painter: _DimHatchPainter(slopeLeft: slopeLeft)),
      ],
    );
  }

  /// Scissors glyph centered in a dim band's VISIBLE region (the
  /// portion that isn't tucked behind the bright body). Signals
  /// "this side is trimmed and will not play". Same metaphor as the
  /// cut tool elsewhere in the canvas. Opacity scales with the expand
  /// animation `t` so it fades in with the bloom; gated above by
  /// [_kDimScissorsMinBandPx] so narrow bands skip the icon rather
  /// than squashing it.
  Widget _buildLeftDimScissors(double bandLeft, double t) {
    // Visible band spans x = [-bandLeft, 0]; centre is at -bandLeft/2.
    // The outer Opacity wires visibility to the bloom animation `t`
    // so the content appears with the bands themselves.
    // AnimatedSwitcher fades + slides the icon out (down) when the
    // band crosses the fit threshold mid-drag.
    final fits = bandLeft > _kDimScissorsMinBandPx;
    final trimmedSource = widget.slice.trimStart - widget.slice.cutStart;
    return Positioned(
      key: const ValueKey('slice-bar-dim-scissors-left'),
      left: -bandLeft,
      top: 0,
      bottom: 0,
      width: bandLeft,
      child: IgnorePointer(
        child: Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: _fitFadeSwitcher(
            fits: fits,
            keyOn: 'dim-scissors-left-fits',
            keyOff: 'dim-scissors-left-hidden',
            content: _dimScissorsContent(
              bandWidth: bandLeft,
              trimmedSource: trimmedSource,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRightDimScissors(double bandRight, double t) {
    // Visible band spans x = [_widthPx, _widthPx + bandRight].
    final fits = bandRight > _kDimScissorsMinBandPx;
    final trimmedSource = widget.slice.cutEnd - widget.slice.trimEnd;
    return Positioned(
      key: const ValueKey('slice-bar-dim-scissors-right'),
      left: _widthPx,
      top: 0,
      bottom: 0,
      width: bandRight,
      child: IgnorePointer(
        child: Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: _fitFadeSwitcher(
            fits: fits,
            keyOn: 'dim-scissors-right-fits',
            keyOff: 'dim-scissors-right-hidden',
            content: _dimScissorsContent(
              bandWidth: bandRight,
              trimmedSource: trimmedSource,
            ),
          ),
        ),
      ),
    );
  }

  /// Cross-fade + slide-up/down between the dim scissors content and
  /// nothing, used when the band crosses the fit threshold mid-drag.
  /// Both children carry distinct keys so AnimatedSwitcher detects
  /// the change. The slide direction (down on appear, down on
  /// disappear) makes the icon look like it drops in from below the
  /// band's bottom edge.
  Widget _fitFadeSwitcher({
    required bool fits,
    required String keyOn,
    required String keyOff,
    required Widget content,
  }) {
    return AnimatedSwitcher(
      duration: _kDimScissorsFitFade,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.4),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: fits
          ? KeyedSubtree(key: ValueKey(keyOn), child: content)
          : SizedBox.shrink(key: ValueKey(keyOff)),
    );
  }

  /// Centered scissors icon, plus a "X.Xs" amount-trimmed label when
  /// the band is wide enough to fit both. Below [_kDimLabelMinBandPx]
  /// the label drops out so the icon doesn't get crushed against text.
  /// Source-time seconds — what the user is removing from the original
  /// footage, not edited-time width.
  Widget _dimScissorsContent({
    required double bandWidth,
    required Duration trimmedSource,
  }) {
    final showLabel =
        bandWidth >= _kDimLabelMinBandPx && trimmedSource > Duration.zero;
    // The label's slot collapses its width per frame (via
    // Align(widthFactor:)) so the icon to its left shifts into its
    // new centred position IN SYNC with the label's fade-and-slide
    // out — instead of waiting for the fade to finish and then
    // snapping over.
    //
    // FittedBox(scaleDown) catches the case where the band shrinks
    // faster than the label-collapse animation can react during a
    // fast drag — the row stays a hair wider than the band for a
    // few frames, and without FittedBox the RenderFlex would log
    // "overflowed on the right". scaleDown only kicks in when the
    // intrinsic exceeds the band, so steady-state visuals are
    // unaffected.
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.content_cut,
              size: _kDimScissorsSize,
              color: Color(0xB3FFFFFF), // white @ 70% alpha
            ),
            _DimCollapsingLabel(
              show: showLabel,
              duration: _kDimScissorsFitFade,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 4),
                  Text(
                    _formatTrimmedSeconds(trimmedSource),
                    style: const TextStyle(
                      color: Color(0xB3FFFFFF),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTrimmedSeconds(Duration d) {
    final s = d.inMilliseconds / 1000.0;
    return '${s.toStringAsFixed(1)}s';
  }

  /// Thin amber glow line at the trim divider — the seam between the
  /// dim band and the bright active region. Vertically inset from the
  /// body's rounded corners so it doesn't visually clash with them.
  /// Opacity scales with the expand animation `t` so it fades in with
  /// the bloom and out when the drag ends.
  Widget _buildLeftTrimDivider(double t) {
    return Positioned(
      key: const ValueKey('slice-bar-trim-divider-left'),
      left: -_kTrimDividerWidth / 2,
      top: _kTrimDividerInset,
      bottom: _kTrimDividerInset,
      width: _kTrimDividerWidth,
      child: IgnorePointer(
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: _trimDividerFill()),
      ),
    );
  }

  Widget _buildRightTrimDivider(double t) {
    return Positioned(
      key: const ValueKey('slice-bar-trim-divider-right'),
      left: _widthPx - _kTrimDividerWidth / 2,
      top: _kTrimDividerInset,
      bottom: _kTrimDividerInset,
      width: _kTrimDividerWidth,
      child: IgnorePointer(
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: _trimDividerFill()),
      ),
    );
  }

  Widget _trimDividerFill() {
    return Container(
      decoration: BoxDecoration(
        // Vertical fade so the line doesn't terminate abruptly into
        // the rounded body corners — alpha is highest in the middle.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            clipFillTop.withValues(alpha: 0.0),
            clipFillTop.withValues(alpha: 0.55),
            clipFillTop.withValues(alpha: 0.0),
          ],
        ),
        borderRadius: BorderRadius.circular(_kTrimDividerWidth / 2),
        boxShadow: [
          BoxShadow(color: clipFillTop.withValues(alpha: 0.35), blurRadius: 4),
        ],
      ),
    );
  }

  /// Ticks are ruler-aligned (same minor-step grid as TimeRulerPainter)
  /// and speed-scaled: faster slice → denser, slower → sparser.
  /// Gated by [_kTicksMinBodyPx].
  Widget _buildTicks() {
    final editedStartPx =
        widget.editedStart.inMilliseconds / 1000.0 * widget.pixelsPerSecond;
    return Positioned(
      key: const ValueKey('slice-bar-ticks'),
      left: 0,
      top: 0,
      width: _widthPx,
      height: laneHeight,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _SliceTickPainter(
            widthPx: _widthPx,
            pixelsPerSecond: widget.pixelsPerSecond,
            editedStartPx: editedStartPx,
            playbackSpeed: widget.slice.playbackSpeed,
          ),
        ),
      ),
    );
  }

  /// "Clip · Ns · 1x" badge centered inside the active region. Always
  /// laid out so AnimatedSwitcher can run the fade+slide transition when
  /// the width crosses the [_kLabelMinBodyPx]/[_kCaptionMinBodyPx]
  /// visibility thresholds during a trim drag. ClipRect + OverflowBox
  /// lets the inner Row keep its natural intrinsic width (no RenderFlex
  /// overflow on narrow slices) while visually clipping anything that
  /// doesn't fit.
  Widget _buildLabel() {
    return Positioned(
      key: const ValueKey('slice-bar-label'),
      left: 0,
      top: 0,
      width: _widthPx,
      height: laneHeight,
      child: IgnorePointer(
        child: ClipRect(
          child: OverflowBox(
            maxWidth: double.infinity,
            maxHeight: laneHeight,
            child: Center(
              child: AnimatedSwitcher(
                duration: _kLabelFadeDuration,
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    // Slide UP from below to appear, slide DOWN to
                    // disappear (begin offset is below resting pos).
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.35),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: _widthPx >= _kLabelMinBodyPx
                    ? _SliceLabel(
                        key: const ValueKey('label-visible'),
                        editedLength: widget.slice.editedLength,
                        playbackSpeed: widget.slice.playbackSpeed,
                        wide: _widthPx >= _kCaptionMinBodyPx,
                      )
                    : const SizedBox.shrink(key: ValueKey('label-hidden')),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Chevron marking the trim boundary in normal mode. Fades out as the
  /// slice expands — once the dim bands are visible they communicate the
  /// same thing.
  Widget _buildLeftChevron(double t) {
    return Positioned(
      key: const ValueKey('slice-bar-left-chevron'),
      left: 0,
      top: 0,
      bottom: 0,
      child: Opacity(
        opacity: (1 - t).clamp(0.0, 1.0),
        child: const _ChevronNotch(pointsRight: false),
      ),
    );
  }

  Widget _buildRightChevron(double t) {
    return Positioned(
      key: const ValueKey('slice-bar-right-chevron'),
      // Inset by [_kInterSliceGap] so the chevron sits at the body's
      // RIGHT EDGE — not at the SliceBar's right edge, which is one
      // gap further out and would float the chevron over the empty
      // seam space between adjacent slices. Matches the left
      // chevron's `left: 0` (body's left edge) on the other side.
      right: _kInterSliceGap,
      top: 0,
      bottom: 0,
      child: Opacity(
        opacity: (1 - t).clamp(0.0, 1.0),
        child: const _ChevronNotch(pointsRight: true),
      ),
    );
  }

  /// Hover-affordance pill on a non-trimmed body edge. Always present in
  /// the tree (so AnimatedOpacity has something to animate to/from);
  /// opacity 0 when the cursor isn't over the slice. Gated above by
  /// `!isLeftTrimmed`/`!isRightTrimmed` because the chevron already
  /// communicates "drag here to restore" on a trimmed edge and two cues
  /// on the same edge would fight.
  Widget _buildLeftHoverPill() {
    return Positioned(
      key: const ValueKey('slice-bar-hover-pill-left'),
      left: _kHandleEdgeInset,
      top: 0,
      bottom: 0,
      width: _kHandleSlotPx,
      child: _hoverPillFill(),
    );
  }

  Widget _buildRightHoverPill() {
    return Positioned(
      key: const ValueKey('slice-bar-hover-pill-right'),
      right: _kHandleEdgeInset,
      top: 0,
      bottom: 0,
      width: _kHandleSlotPx,
      child: _hoverPillFill(),
    );
  }

  Widget _hoverPillFill() {
    return IgnorePointer(
      child: Center(
        child: AnimatedOpacity(
          duration: _kHoverFade,
          opacity: _hovered ? 1.0 : 0.0,
          child: Container(
            width: _kHandlePillWidth,
            height: _kHandlePillHeight,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(_kHandlePillWidth / 2),
            ),
          ),
        ),
      ),
    );
  }

  /// Offset amber stroke sitting OUTSIDE the body with a transparent gap.
  /// Tracks the body's animated extents (so it grows with the expand
  /// bloom during a trim drag). Gentle pulse on the stroke alpha.
  Widget _buildSelectionRing({
    required double bandLeft,
    required double totalWidth,
    required double glowT,
  }) {
    return Positioned(
      key: const ValueKey('slice-bar-selection-ring'),
      left: -bandLeft - _kRingInset,
      top: -_kRingInset,
      width: totalWidth + _kRingInset * 2,
      height: laneHeight + _kRingInset * 2,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kRingRadius),
            border: Border.all(
              color: clipFillTop.withValues(alpha: 0.65 + 0.30 * glowT),
              width: _kRingStroke,
            ),
          ),
        ),
      ),
    );
  }

  /// Trim handles stay anchored to the ACTIVE region's edges in every
  /// state — dragging outward into the dim band restores trim, which
  /// shrinks the band on the next frame.
  Widget _buildLeftHandle() {
    return Positioned(
      key: const ValueKey('slice-bar-left-handle-pos'),
      left: 0,
      top: 0,
      bottom: 0,
      width: handleHitWidth,
      child: GestureDetector(
        key: const ValueKey('slice-bar-left-handle'),
        behavior: HitTestBehavior.translucent,
        // dragStartBehavior.down so the slop pixels are delivered as
        // part of the first update, not silently eaten by the gesture
        // arena win.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: _onLeftDragStart,
        onHorizontalDragUpdate: _onLeftDragUpdate,
        onHorizontalDragEnd: _onLeftDragEnd,
        onHorizontalDragCancel: _onLeftDragCancel,
        child: const MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildRightHandle() {
    return Positioned(
      key: const ValueKey('slice-bar-right-handle-pos'),
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
        onHorizontalDragEnd: _onRightDragEnd,
        onHorizontalDragCancel: _onRightDragCancel,
        child: const MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: SizedBox.expand(),
        ),
      ),
    );
  }
}

/// Three-stop vertical gradient derived from a single body colour:
/// +5% lightness at the top edge, base in the middle, -8% lightness at
/// the bottom edge. Reads as a soft "lit from above" highlight without
/// pulling the colour off-hue.
List<Color> _bodyGradientColors(Color base) {
  final hsl = HSLColor.fromColor(base);
  final top = hsl
      .withLightness((hsl.lightness + 0.05).clamp(0.0, 1.0))
      .toColor();
  final bottom = hsl
      .withLightness((hsl.lightness - 0.08).clamp(0.0, 1.0))
      .toColor();
  return [top, base, bottom];
}

/// Three-stop vertical gradient for the trim "dim" sibling bands —
/// same lit-from-above structure as the body but knocked down 42
/// lightness points in HSL space so the band reads as a darker ghost
/// of the active region in the same colour family rather than a
/// neutral grey block.
List<Color> _dimGradientColors(Color base) {
  final hsl = HSLColor.fromColor(
    base,
  ).withLightness((HSLColor.fromColor(base).lightness - 0.42).clamp(0.05, 1.0));
  final top = hsl
      .withLightness((hsl.lightness + 0.04).clamp(0.0, 1.0))
      .toColor();
  final mid = hsl.toColor();
  final bottom = hsl
      .withLightness((hsl.lightness - 0.06).clamp(0.0, 1.0))
      .toColor();
  return [top, mid, bottom];
}

class _ChevronNotch extends StatelessWidget {
  const _ChevronNotch({required this.pointsRight});
  final bool pointsRight;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        pointsRight ? Icons.chevron_right : Icons.chevron_left,
        color: Colors.white,
        size: 14,
      ),
    );
  }
}

/// Paints faint vertical tick marks inside the slice body, aligned to
/// the time ruler's minor-dot grid. At 1× speed, each tick falls on a
/// ruler minor dot. Faster slices subdivide the interval (denser ticks),
/// slower slices expand it (sparser ticks). If the speed-scaled step
/// would be too tight to read, it is coarsened until it clears the
/// minimum spacing threshold.
class _SliceTickPainter extends CustomPainter {
  const _SliceTickPainter({
    required this.widthPx,
    required this.pixelsPerSecond,
    required this.editedStartPx,
    required this.playbackSpeed,
  });

  final double widthPx;
  final double pixelsPerSecond;
  // Content-space x of this slice's left (edited-time) edge. Used to
  // align ticks to the ruler's time grid rather than the slice's own
  // left edge, so ticks at 1× coincide with ruler dots regardless of
  // where in the timeline the slice starts.
  final double editedStartPx;
  final double playbackSpeed;

  // Match TimeRulerPainter's tuning constants exactly so the grids share
  // the same step sizes at every zoom level.
  static const double _targetMajorPx = 90.0;
  static const int _minorDivisions = 5;
  static const double _minTickSpacingPx = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (widthPx <= 0 || pixelsPerSecond <= 0) return;
    final speed = playbackSpeed > 0 ? playbackSpeed : 1.0;

    // Derive the ruler's minor step in edited pixels.
    final majorStep = math.max(
      1.0,
      _niceStep(_targetMajorPx / pixelsPerSecond),
    );
    final minorStepSec = majorStep / _minorDivisions;
    // Scale by playbackSpeed: a 2× slice compresses 2 source-seconds
    // into 1 edited second, so ticks appear 2× closer in edited space.
    var tickStepSec = minorStepSec / speed;
    var tickStepPx = tickStepSec * pixelsPerSecond;

    // Coarsen until ticks are wide enough to read as distinct lines.
    // Step through the same 1-2-5 family so the coarsening snaps to
    // the next level the ruler would use, not an arbitrary multiple.
    if (tickStepPx < _minTickSpacingPx) {
      // Multiply up through minor→major→2×major→5×major… until readable.
      for (final factor in [
        _minorDivisions,
        _minorDivisions * 2,
        _minorDivisions * 5,
        _minorDivisions * 10,
      ]) {
        tickStepSec = (minorStepSec / speed) * factor;
        tickStepPx = tickStepSec * pixelsPerSecond;
        if (tickStepPx >= _minTickSpacingPx) break;
      }
    }
    if (tickStepPx <= 0) return;

    // First tick in content space that is at or after this slice's left
    // edge, snapped to the ruler-aligned grid (origin = time 0).
    final firstTickContentX =
        (editedStartPx / tickStepPx).ceil() * tickStepPx;
    var localX = firstTickContentX - editedStartPx;

    const inset = 4.0;
    final top = inset;
    final bottom = size.height - inset;
    final gradient = ui.Gradient.linear(Offset(0, top), Offset(0, bottom), [
      clipStroke.withValues(alpha: 0.55),
      clipStroke.withValues(alpha: 0.06),
    ]);
    final paint = Paint()
      ..shader = gradient
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // Suppress ticks within 6 px of either edge so they don't merge
    // with the slice body's left/right visual boundary.
    const edgeSuppressionPx = 6.0;
    while (localX < widthPx - edgeSuppressionPx) {
      if (localX > edgeSuppressionPx) {
        canvas.drawLine(
          Offset(localX + 0.5, top),
          Offset(localX + 0.5, bottom),
          paint,
        );
      }
      localX += tickStepPx;
    }
  }

  // Same 1-2-5 nice-number algorithm as TimeRulerPainter._niceStep.
  static double _niceStep(double rough) {
    if (rough <= 0) return 1;
    final exp = (math.log(rough) / math.ln10).floor();
    final magnitude = math.pow(10.0, exp).toDouble();
    final normalized = rough / magnitude;
    if (normalized <= 1) return magnitude;
    if (normalized <= 2) return 2 * magnitude;
    if (normalized <= 5) return 5 * magnitude;
    return 10 * magnitude;
  }

  @override
  bool shouldRepaint(_SliceTickPainter old) =>
      old.widthPx != widthPx ||
      old.pixelsPerSecond != pixelsPerSecond ||
      old.editedStartPx != editedStartPx ||
      old.playbackSpeed != playbackSpeed;
}

/// Faint 45° diagonal hatch overlay painted across a dim trim band.
/// Communicates "this content is removed" at any width — reinforces
/// the scissors glyph when the band is wide enough to show it, and
/// carries the meaning alone on narrow bands where the icon faded out.
///
/// [slopeLeft] mirrors the line direction so left and right bands
/// lean toward each other across the bright body, reading as a single
/// trim shape rather than two unrelated textures.
class _DimHatchPainter extends CustomPainter {
  const _DimHatchPainter({required this.slopeLeft});

  final bool slopeLeft;

  // Spacing + stroke chosen by eye: dense enough to read as texture,
  // sparse enough that the underlying gradient still does the heavy
  // lifting for the "dim" cue. Alpha tuned so the hatch is visible on
  // hover but never competes with the scissors glyph.
  static const double _step = 6.0;
  static const double _stroke = 1.0;
  static const Color _color = Color(0x1AFFFFFF); // white @ ~10% alpha

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = _color
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.square;
    // Each line is a 45° diagonal sweeping the full hatch height.
    // We start at (offset, 0) and end at (offset ± height, height).
    // Sliding `offset` from -height to +width sweeps the whole rect.
    final h = size.height;
    final dirX = slopeLeft ? -1.0 : 1.0;
    for (var offset = -h; offset < size.width + h; offset += _step) {
      canvas.drawLine(Offset(offset, 0), Offset(offset + dirX * h, h), paint);
    }
  }

  @override
  bool shouldRepaint(_DimHatchPainter old) => old.slopeLeft != slopeLeft;
}

/// Centered "Clip / Ns · 1x" badge inside the slice body. [wide] toggles
/// the "Clip" caption row — narrow slices show only the duration+speed
/// line so the text doesn't overflow.
class _SliceLabel extends StatelessWidget {
  const _SliceLabel({
    super.key,
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
          // Inner "Clip" caption — appears only on wider slices.
          // AnimatedSize handles the height collapse so the row
          // below smoothly re-centers, AnimatedSwitcher cross-fades
          // and slides the caption (down from above to appear, up
          // and out to disappear).
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.5),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: wide
                  ? Column(
                      key: const ValueKey('caption-visible'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Clip', style: captionStyle),
                        const SizedBox(height: 1),
                      ],
                    )
                  : const SizedBox.shrink(key: ValueKey('caption-hidden')),
            ),
          ),
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

/// Slot for the dim band's seconds label that tweens its WIDTH per
/// frame as [show] toggles. The slot's effective width is the child's
/// intrinsic width × value, so the icon next to it shifts smoothly
/// instead of waiting for a fade transition to complete and then
/// snapping into place. Also fades the child + slides it down so it
/// doesn't just blink in/out.
class _DimCollapsingLabel extends StatelessWidget {
  const _DimCollapsingLabel({
    required this.show,
    required this.duration,
    required this.child,
  });

  final bool show;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: show ? 1.0 : 0.0, end: show ? 1.0 : 0.0),
      duration: duration,
      curve: Curves.easeOut,
      builder: (context, value, c) {
        return ClipRect(
          child: Align(
            widthFactor: value,
            alignment: AlignmentDirectional.centerStart,
            child: Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 4),
                child: c,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}
