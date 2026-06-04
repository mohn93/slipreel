import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

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
    this.glowLeft = false,
    this.glowRight = false,
  });

  final ClipSlice slice;
  final int sliceIndex;
  final bool isSelected;
  final double pixelsPerSecond;
  final Duration editedStart;
  final ValueChanged<int> onSelectionToggle;
  final ValueChanged<Duration> onTrimStartChanged;
  final ValueChanged<Duration> onTrimEndChanged;
  // When true this slice is the right-neighbour of the currently
  // selected slice and should paint an amber halo bleeding inward
  // from its LEFT edge. Likewise glowRight for the left-neighbour.
  // ClipLane sets these so the selected slice's selection halo
  // visually spills into its immediate neighbours.
  final bool glowLeft;
  final bool glowRight;
  // Fires true/false at the start/end of either trim handle's drag.
  // Lets the parent ClipLane reorder this slice to the top of the
  // Stack and dim its siblings for the duration of the drag, so the
  // expanded "show me the trim regions" bloom isn't occluded by
  // adjacent slices.
  final ValueChanged<bool>? onTrimDragChanged;

  @override
  State<SliceBar> createState() => _SliceBarState();
}

class _SliceBarState extends State<SliceBar>
    with TickerProviderStateMixin {
  // Anchors capture both the trim Duration AND the gesture's starting
  // global x at drag-start. Computing each update against the start
  // position (rather than accumulating frame-by-frame deltas) avoids
  // losing the pre-slop pixels that the gesture arena consumes before
  // the first update fires.
  Duration? _trimStartAnchor;
  Duration? _trimEndAnchor;
  double? _dragStartGlobalX;

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

  // Neighbour halo: amber gradient bleeding from the seam inward to
  // ~60px. Long enough to feel "natural", short enough not to swallow
  // a narrow neighbour entirely.
  static const double _kNeighborGlowPx = 60.0;

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

  // Inset for the dim trim bands. Sized to the body's selected-state
  // border (2px) so the white border isn't darkened by the overlay.
  // Outer corner radius is the body's 8px outer radius minus the inset
  // — matches the body's inner border curve at the rounded corners.
  static const double _kDimInset = 2.0;
  static const double _kDimOuterRadius = 6.0;

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
  }

  void _setDragging(bool dragging) {
    if (dragging) {
      _expand.forward();
    } else {
      _expand.reverse();
    }
    widget.onTrimDragChanged?.call(dragging);
  }

  // True iff _expand is parked above 0 without animating — i.e., the
  // controller never received its reverse signal. Drives the safety
  // recovery in [_maybeRecoverFromStuckDrag] and the onTap fallback.
  bool get _expandIsStuck => _expand.value > 0 && !_expand.isAnimating;

  void _maybeRecoverFromStuckDrag() {
    if (!_expandIsStuck) return;
    _expand.value = 0;
    widget.onTrimDragChanged?.call(false);
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
    final speed =
        widget.slice.playbackSpeed > 0 ? widget.slice.playbackSpeed : 1.0;
    return sourceDelta.inMilliseconds / 1000.0 / speed * widget.pixelsPerSecond;
  }

  // The slice is rendered in EDITED time on the timeline, so 1 pixel
  // corresponds to `1 / pixelsPerSecond` edited seconds. The underlying
  // trim bounds live in SOURCE time, so converting a pixel delta back to
  // a trim delta multiplies by playbackSpeed (1 edited-second of drag =
  // `speed` source-seconds of trim movement at the slice's speed).
  double get _widthPx =>
      widget.slice.editedLength.inMilliseconds / 1000.0 * widget.pixelsPerSecond;
  double get _sourceSecondsPerPixel {
    if (widget.pixelsPerSecond <= 0) return 0;
    final speed =
        widget.slice.playbackSpeed > 0 ? widget.slice.playbackSpeed : 1.0;
    return speed / widget.pixelsPerSecond;
  }

  void _onLeftDragStart(DragStartDetails d) {
    _trimStartAnchor = widget.slice.trimStart;
    _dragStartGlobalX = d.globalPosition.dx;
    _setDragging(true);
  }

  void _onLeftDragUpdate(DragUpdateDetails d) {
    final anchor = _trimStartAnchor;
    final startX = _dragStartGlobalX;
    if (anchor == null || startX == null) return;
    final deltaSec = (d.globalPosition.dx - startX) * _sourceSecondsPerPixel;
    final next = anchor + Duration(microseconds: (deltaSec * 1e6).round());
    widget.onTrimStartChanged(next);
  }

  void _onLeftDragEnd(DragEndDetails _) => _setDragging(false);
  void _onLeftDragCancel() => _setDragging(false);

  void _onRightDragStart(DragStartDetails d) {
    _trimEndAnchor = widget.slice.trimEnd;
    _dragStartGlobalX = d.globalPosition.dx;
    _setDragging(true);
  }

  void _onRightDragUpdate(DragUpdateDetails d) {
    final anchor = _trimEndAnchor;
    final startX = _dragStartGlobalX;
    if (anchor == null || startX == null) return;
    final deltaSec = (d.globalPosition.dx - startX) * _sourceSecondsPerPixel;
    final next = anchor + Duration(microseconds: (deltaSec * 1e6).round());
    widget.onTrimEndChanged(next);
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
        final bandLeft = t * _leftFullGhostPx;
        final bandRight = t * _rightFullGhostPx;
        final totalWidth = bandLeft + _widthPx + bandRight;
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
                    _buildBody(
                        isSel: isSel,
                        bandLeft: bandLeft,
                        totalWidth: totalWidth),
                    if (bandLeft > _kDimInset) _buildLeftDimBand(bandLeft, t),
                    if (bandRight > _kDimInset)
                      _buildRightDimBand(bandRight, t),
                    if (widget.glowLeft) _buildNeighborHaloLeft(),
                    if (widget.glowRight) _buildNeighborHaloRight(),
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

  /// Expanded body. In normal mode it's exactly the active region
  /// (_widthPx); during a trim drag it widens to the full cutSpan, with
  /// the dim bands drawn on top of the outer thirds.
  Widget _buildBody({
    required bool isSel,
    required double bandLeft,
    required double totalWidth,
  }) {
    return Positioned(
      key: const ValueKey('slice-bar-body-pos'),
      left: -bandLeft,
      top: 0,
      width: totalWidth,
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

  /// Dim band over the left-trimmed source. Sits on top of the body so
  /// it darkens the body color in that range. Border radius rounded only
  /// on the OUTER side so the band visually continues into the active
  /// region. Inset by [_kDimInset] on every body-edge side so the
  /// selected ring's border stays visible — the overlay would otherwise
  /// darken the white border too. The inner (active-side) edge has no
  /// inset because that boundary is inside the body and has no border
  /// there.
  Widget _buildLeftDimBand(double bandLeft, double t) {
    return Positioned(
      key: const ValueKey('slice-bar-dim-left'),
      left: -bandLeft + _kDimInset,
      top: _kDimInset,
      bottom: _kDimInset,
      width: bandLeft - _kDimInset,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5 * t),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(_kDimOuterRadius),
              bottomLeft: Radius.circular(_kDimOuterRadius),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRightDimBand(double bandRight, double t) {
    return Positioned(
      key: const ValueKey('slice-bar-dim-right'),
      left: _widthPx,
      top: _kDimInset,
      bottom: _kDimInset,
      width: bandRight - _kDimInset,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5 * t),
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(_kDimOuterRadius),
              bottomRight: Radius.circular(_kDimOuterRadius),
            ),
          ),
        ),
      ),
    );
  }

  /// Amber gradient bleeding inward from the seam between this slice
  /// and the currently selected slice. ~60px wide, clipped to the body's
  /// rounded outer corners on that side.
  Widget _buildNeighborHaloLeft() {
    return Positioned(
      key: const ValueKey('slice-bar-neighbor-glow-left'),
      left: 0,
      top: 0,
      width: _kNeighborGlowPx,
      height: laneHeight,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              bottomLeft: Radius.circular(8),
            ),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                clipFillTop.withValues(alpha: 0.55),
                clipFillTop.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNeighborHaloRight() {
    return Positioned(
      key: const ValueKey('slice-bar-neighbor-glow-right'),
      right: 0,
      top: 0,
      width: _kNeighborGlowPx,
      height: laneHeight,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(8),
              bottomRight: Radius.circular(8),
            ),
            gradient: LinearGradient(
              begin: Alignment.centerRight,
              end: Alignment.centerLeft,
              colors: [
                clipFillTop.withValues(alpha: 0.55),
                clipFillTop.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tick rhythm scales inversely with playbackSpeed: faster slice →
  /// denser ticks, slower slice → sparser. Gated above by the
  /// [_kTicksMinBodyPx] threshold.
  Widget _buildTicks() {
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
                    : const SizedBox.shrink(
                        key: ValueKey('label-hidden'),
                      ),
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
      right: 0,
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
              color: clipFillTop.withValues(
                alpha: 0.65 + 0.30 * glowT,
              ),
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
  final top = hsl.withLightness((hsl.lightness + 0.05).clamp(0.0, 1.0)).toColor();
  final bottom = hsl.withLightness((hsl.lightness - 0.08).clamp(0.0, 1.0)).toColor();
  return [top, base, bottom];
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

/// Paints faint vertical tick marks inside the slice body. The step is
/// `_baseStepPx / playbackSpeed` (in edited pixels), so a 4× slice
/// shows ticks 4× closer than a 1× slice. The step is clamped to a
/// minimum so very fast slices don't degenerate into a solid bar.
class _SliceTickPainter extends CustomPainter {
  const _SliceTickPainter({
    required this.widthPx,
    required this.playbackSpeed,
  });

  final double widthPx;
  final double playbackSpeed;

  // Roughly a half-second visual rhythm at 1× and default timeline zoom.
  // Picked by eye, not derived — the request is a felt rhythm, not a
  // time-accurate ruler (the actual time ruler lives above the lane).
  static const double _baseStepPx = 32.0;
  static const double _minStepPx = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (widthPx <= 0) return;
    final speed = playbackSpeed > 0 ? playbackSpeed : 1.0;
    var stepPx = _baseStepPx / speed;
    if (stepPx < _minStepPx) stepPx = _minStepPx;
    // Snap to an integer pixel count and advance by that exact integer
    // per tick. Per-tick rounding alternates N/N+1 spacings when stepPx
    // lands near a half-integer, which reads as "some bunched, some
    // spread" even though the underlying math is uniform.
    final stepPxInt = stepPx.round();
    if (stepPxInt <= 0) return;
    const inset = 4.0;
    final top = inset;
    final bottom = size.height - inset;
    // Vertical gradient on each tick: prominent at the top (~55% alpha),
    // fading to nearly invisible at the bottom. Same shader is reused
    // for every tick — strokes the column at x using the gradient's y
    // values, so each line gets the top→bottom fade locally.
    final gradient = ui.Gradient.linear(
      Offset(0, top),
      Offset(0, bottom),
      [
        clipStroke.withValues(alpha: 0.55),
        clipStroke.withValues(alpha: 0.06),
      ],
    );
    final paint = Paint()
      ..shader = gradient
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    // Skip ticks near the right edge so they don't visually merge with
    // the seam between slices (which already paints a strong vertical
    // line at that x).
    const edgeSuppressionPx = 6.0;
    final lastDrawX = widthPx - edgeSuppressionPx;
    for (var x = stepPxInt; x < lastDrawX; x += stepPxInt) {
      canvas.drawLine(
        Offset(x + 0.5, top),
        Offset(x + 0.5, bottom),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SliceTickPainter old) =>
      old.widthPx != widthPx || old.playbackSpeed != playbackSpeed;
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
                  : const SizedBox.shrink(
                      key: ValueKey('caption-hidden'),
                    ),
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
