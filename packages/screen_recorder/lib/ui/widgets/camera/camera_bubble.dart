import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/editor/camera_snap.dart';
import 'package:slipreel_engine/models/camera_settings.dart';

/// The camera PiP bubble, laid out in CANVAS coordinate space (the same
/// `totalSize` space `PlaybackCanvas` composes in). Given a normalized
/// [placement] it computes the pixel box (width from `placement.size`,
/// height derived from the global [settings.shape]'s pixel-aspect), then
/// applies mirror -> shape clip + roundness -> border -> shadow -> opacity to
/// the [child] (a `VideoPlayer`, or any widget in tests).
///
/// When [selected] is true AND [onPlacementChanged] is non-null the bubble
/// is interactive: drag the body to move (reports new centerX/centerY) and
/// drag a corner handle to resize (reports new size). All deltas are
/// converted back to normalized canvas space using [canvasSize].
class CameraBubble extends StatelessWidget {
  const CameraBubble({
    super.key,
    required this.canvasSize,
    required this.placement,
    required this.settings,
    required this.child,
    this.originalAspect = 1.0,
    this.selected = false,
    this.onPlacementChanged,
    this.onPlacementCommit,
    this.onSelectRequested,
    this.reveal = 1.0,
  });

  /// Reveal progress 0..1 for the vanish/appear animation: 1 = fully shown,
  /// 0 = hidden (faded out, blurred, and slid down). Driven by
  /// [AnimatedCameraBubble].
  final double reveal;

  /// The canvas (`totalSize`) this bubble is positioned within.
  final Size canvasSize;
  final CameraPlacement placement;
  final CameraSettings settings;

  /// The camera source's width/height; used only when shape == original.
  final double originalAspect;

  final Widget child;
  final bool selected;

  /// When non-null and [selected], the bubble is editable; called with the
  /// new normalized placement during drag/resize (every pointer move).
  final ValueChanged<CameraPlacement>? onPlacementChanged;

  /// Called once when a move/resize drag ENDS — the caller commits the live
  /// preview to persisted state here (keeping per-move updates cheap).
  final VoidCallback? onPlacementCommit;

  /// When non-null and the bubble is NOT yet the editable selection, tapping
  /// the bubble on the canvas calls this to select it (so the user can grab it
  /// straight from the preview without finding its timeline pill).
  final VoidCallback? onSelectRequested;

  static const double _minSize = 0.05;
  static const double _maxSize = 1.2;

  Rect _pixelBox() => cameraPixelBox(
        centerX: placement.centerX,
        centerY: placement.centerY,
        size: placement.size,
        canvasSize: canvasSize,
        shapeAspect: settings.shape.pixelAspect(originalAspect),
      );


  @override
  Widget build(BuildContext context) {
    final box = _pixelBox();

    Widget framed = SizedBox(
      key: const Key('camera-bubble-box'),
      width: box.width,
      height: box.height,
      child: _clipped(child),
    );

    // Mirror (horizontal flip) around the box center. diagonal3Values(-1,1,1)
    // scales x by -1 -> a horizontal flip in place with alignment center.
    if (settings.mirror) {
      framed = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: framed,
      );
    }

    // Border + shadow live on a container sized to the box, behind the clip.
    Widget decorated = framed;
    if (settings.borderWidth > 0 || settings.shadow) {
      decorated = Container(
        width: box.width,
        height: box.height,
        decoration: BoxDecoration(
          shape: settings.shape.isRound ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: settings.shape.isRound
              ? null
              : BorderRadius.circular(_cornerRadius(box)),
          border: settings.borderWidth > 0
              ? Border.all(
                  color: Color(settings.borderColor),
                  width: settings.borderWidth,
                )
              : null,
          boxShadow: settings.shadow
              ? const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: framed,
      );
    }

    Widget bubble = Opacity(
      key: const Key('camera-bubble-opacity'),
      opacity: (settings.opacity * reveal).clamp(0.0, 1.0),
      child: decorated,
    );

    // The active region's bubble is grab-and-drag movable even before it's the
    // selected one — a drag (or tap) selects it. Resize handles, the selection
    // ring, and the snap guides only appear once selected. The affordance
    // wrapper keeps a STABLE structure across selection (the move GestureDetector
    // is always present) so a drag that selects mid-gesture isn't cancelled.
    final canMove = onPlacementChanged != null;

    // The affordance wrapper inflates the hit area by handle/2 per side; shift
    // the origin back so the bubble stays visually put.
    const handleInset = 8.0; // _withEditAffordances.handle / 2 = 16/2
    final posLeft = canMove ? box.left - handleInset : box.left;
    final posTop = canMove ? box.top - handleInset : box.top;

    if (canMove) {
      bubble = _withEditAffordances(bubble, box, showHandles: selected);
    } else if (onSelectRequested != null) {
      // No move callback (e.g. not the active region) — a tap still selects it.
      bubble = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelectRequested,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: bubble),
      );
    }

    // Vanish/appear animation: blur out + slide down as it fades. Skip the
    // (cost-y) blur layer once essentially revealed.
    final hidden = (1.0 - reveal).clamp(0.0, 1.0);
    if (hidden > 0.01) {
      bubble = ImageFiltered(
        imageFilter:
            ImageFilter.blur(sigmaX: hidden * 12, sigmaY: hidden * 12),
        child: bubble,
      );
    }
    final slideY = hidden * 20.0; // slides up into place / down on vanish

    // Self-contained: the bubble fills the canvas and positions its box in an
    // internal Stack, so it can be dropped straight into PlaybackCanvas (or a
    // test) without the caller providing a Stack.
    return SizedBox(
      width: canvasSize.width,
      height: canvasSize.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Faint snap-anchor guides, shown once the bubble is selected.
          if (canMove && selected) ..._anchorGuides(),
          Positioned(left: posLeft, top: posTop + slideY, child: bubble),
        ],
      ),
    );
  }

  /// The 9 standard snap targets rendered as faint dots, shown while the
  /// bubble is being edited so the user can see where it will snap.
  List<Widget> _anchorGuides() {
    const dot = 10.0;
    final ca =
        canvasSize.height == 0 ? 1.0 : canvasSize.width / canvasSize.height;
    final ext = cameraHalfExtents(
      size: placement.size,
      shapeAspect: settings.shape.pixelAspect(originalAspect),
      canvasAspect: ca,
    );
    return [
      for (final a in cameraSnapAnchors(halfW: ext.halfW, halfH: ext.halfH))
        Positioned(
          left: a.dx * canvasSize.width - dot / 2,
          top: a.dy * canvasSize.height - dot / 2,
          child: IgnorePointer(
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: const Color(0x336C63FF),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x886C63FF)),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _clipped(Widget c) {
    // A `VideoPlayer` (Texture) has NO intrinsic size; placed directly in a
    // FittedBox it is measured under unbounded constraints and collapses to
    // 0x0, so nothing paints (the bubble's shadow/border still render → the
    // "shadow but no video" symptom). Give the child a concrete,
    // correctly-proportioned box (width:aspect, height:1) so BoxFit.cover has
    // a real size to scale to fill the bubble. Only the ratio matters — the
    // texture is resolution-independent, so the 1px-tall box scales cleanly.
    final aspect =
        (originalAspect.isFinite && originalAspect > 0) ? originalAspect : 1.0;
    final fitted = FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(width: aspect, height: 1.0, child: c),
    );
    if (settings.shape.isRound) {
      return ClipOval(child: fitted);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(_cornerRadiusFor(placement.size)),
      child: fitted,
    );
  }

  double _cornerRadius(Rect box) {
    if (settings.shape.isRound) return box.shortestSide / 2;
    return settings.roundness.clamp(0.0, 1.0) * (box.shortestSide / 2);
  }

  // Roundness in normalized terms for the clip (uses the smaller pixel side).
  double _cornerRadiusFor(double size) {
    final w = size * canvasSize.width;
    final aspect = settings.shape.pixelAspect(originalAspect);
    final h = w / aspect;
    final shortest = w < h ? w : h;
    return settings.roundness.clamp(0.0, 1.0) * (shortest / 2);
  }

  Widget _withEditAffordances(Widget bubble, Rect box,
      {required bool showHandles}) {
    const handle = 16.0;
    // Handles are centred on the bubble corners. The outer SizedBox is inflated
    // by handle/2 on every side, so each corner sits flush at the outer edges
    // (offset 0 from each side = handle/2 pixels around the bubble corner).
    Widget cornerHandle(String id, Alignment a) => Positioned(
          left: a.x < 0 ? 0 : null,
          right: a.x > 0 ? 0 : null,
          top: a.y < 0 ? 0 : null,
          bottom: a.y > 0 ? 0 : null,
          child: GestureDetector(
            key: Key('camera-handle-$id'),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => _resizeBy(d.delta, a),
            onPanEnd: (_) => onPlacementCommit?.call(),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: Container(
                width: handle,
                height: handle,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF6C63FF), width: 2),
                ),
              ),
            ),
          ),
        );

    // Inflate the hit-testable area by handle/2 on each side so that corner
    // handles (which hang half-outside the bubble box) are reachable by pointer
    // events. The inner content is offset back by the same amount so it renders
    // at the correct visual position.
    const inset = handle / 2;
    return SizedBox(
      width: box.width + handle,
      height: box.height + handle,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Offset the bubble content back to its visual position within the
          // inflated SizedBox.
          Positioned(
            left: inset,
            top: inset,
            child: SizedBox(
              width: box.width,
              height: box.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Move handle = the body. Always present (stable across
                  // selection). Drag moves; a tap or drag-start also selects so
                  // the inspector + handles follow. Stateful so the drag
                  // accumulates against a synchronous local base instead of the
                  // async placement (see _CameraMoveBody).
                  _CameraMoveBody(
                    placement: placement,
                    canvasSize: canvasSize,
                    settings: settings,
                    originalAspect: originalAspect,
                    onPlacementChanged: onPlacementChanged,
                    onPlacementCommit: onPlacementCommit,
                    onSelectRequested: onSelectRequested,
                    child: bubble,
                  ),
                  // Selection ring — only when selected.
                  if (showHandles)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: settings.shape.isRound
                                ? BoxShape.circle
                                : BoxShape.rectangle,
                            border: Border.all(
                                color: const Color(0xFF6C63FF), width: 1.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (showHandles) ...[
            cornerHandle('tl', Alignment.topLeft),
            cornerHandle('tr', Alignment.topRight),
            cornerHandle('bl', Alignment.bottomLeft),
            cornerHandle('br', Alignment.bottomRight),
          ],
        ],
      ),
    );
  }

  void _resizeBy(Offset deltaPx, Alignment corner) {
    final cb = onPlacementChanged;
    if (cb == null) return;
    // Dragging a corner outward (away from center) grows the box. Project the
    // drag onto the outward diagonal of this corner and convert to a width
    // fraction of canvas width.
    final outward = (deltaPx.dx * corner.x + deltaPx.dy * corner.y);
    final dSize = outward / canvasSize.width;
    cb(CameraPlacement(
      centerX: placement.centerX,
      centerY: placement.centerY,
      size: (placement.size + dSize).clamp(_minSize, _maxSize),
    ));
  }
}

/// The bubble body as a drag-to-move target.
///
/// Stateful on purpose: it accumulates the drag against a *synchronous, local*
/// base ([_liveRaw]) rather than the parent's [placement]. During a drag the
/// placement only catches up a frame later (the canvas pushes each move through
/// a `ValueNotifier` → `ValueListenableBuilder.setState`), but macOS delivers
/// several pointer-moves per frame. If each move re-read the (stale) placement
/// as its base, every move but the last in a frame would be overwritten and the
/// box would trail the mouse — the "heavy" feel. Keeping the base local fixes
/// that. The base is also kept *unsnapped* (snap is applied only to the reported
/// value), so a slow drag near an anchor still slips past it instead of sticking.
class _CameraMoveBody extends StatefulWidget {
  const _CameraMoveBody({
    required this.placement,
    required this.canvasSize,
    required this.settings,
    required this.originalAspect,
    required this.onPlacementChanged,
    required this.onPlacementCommit,
    required this.onSelectRequested,
    required this.child,
  });

  final CameraPlacement placement;
  final Size canvasSize;
  final CameraSettings settings;
  final double originalAspect;
  final ValueChanged<CameraPlacement>? onPlacementChanged;
  final VoidCallback? onPlacementCommit;
  final VoidCallback? onSelectRequested;
  final Widget child;

  @override
  State<_CameraMoveBody> createState() => _CameraMoveBodyState();
}

class _CameraMoveBodyState extends State<_CameraMoveBody> {
  /// True (unsnapped, in-view-clamped) center while a drag is in flight; null
  /// between drags. Mutated synchronously in [_update] — not via setState, since
  /// the visible position flows back through the parent's placement.
  Offset? _liveRaw;

  void _start() {
    final p = widget.placement;
    _liveRaw = Offset(p.centerX, p.centerY);
    widget.onSelectRequested?.call();
  }

  void _update(Offset deltaPx) {
    final cb = widget.onPlacementChanged;
    if (cb == null) return;
    final cs = widget.canvasSize;
    final p = widget.placement;
    final shapeAspect = widget.settings.shape.pixelAspect(widget.originalAspect);
    final base = _liveRaw ?? Offset(p.centerX, p.centerY);
    final ca = cs.height == 0 ? 1.0 : cs.width / cs.height;
    final ext = cameraHalfExtents(
        size: p.size, shapeAspect: shapeAspect, canvasAspect: ca);
    // Accumulate the true center 1:1 with the pointer, clamped to view so it
    // can't run off the edge and rubber-band on the way back.
    final clamped = clampCameraCenterInView(
      centerX: base.dx + deltaPx.dx / cs.width,
      centerY: base.dy + deltaPx.dy / cs.height,
      halfW: ext.halfW,
      halfH: ext.halfH,
    );
    _liveRaw = Offset(clamped.cx, clamped.cy);
    final double nx, ny;
    if (HardwareKeyboard.instance.isAltPressed) {
      // Free move — no anchor snap, but still kept fully in view.
      nx = clamped.cx;
      ny = clamped.cy;
    } else {
      final snap = snapCameraCenter(
        centerX: clamped.cx,
        centerY: clamped.cy,
        canvasSize: cs,
        size: p.size,
        shapeAspect: shapeAspect,
      );
      nx = snap.center.dx;
      ny = snap.center.dy;
    }
    cb(CameraPlacement(centerX: nx, centerY: ny, size: p.size));
  }

  void _end() {
    _liveRaw = null;
    widget.onPlacementCommit?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('camera-move-body'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onSelectRequested,
      onPanStart: (_) => _start(),
      onPanUpdate: (d) => _update(d.delta),
      onPanEnd: (_) => _end(),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: widget.child,
      ),
    );
  }
}

/// Wraps [CameraBubble] with a vanish/appear animation driven by [visible]:
/// the bubble fades, blurs, and slides as the camera enters or leaves an active
/// region. It stays mounted through the exit animation, then collapses to
/// nothing. While appearing or vanishing the bubble is non-interactive — only a
/// settled, visible bubble can be grabbed/dragged.
class AnimatedCameraBubble extends StatefulWidget {
  const AnimatedCameraBubble({
    super.key,
    required this.visible,
    required this.canvasSize,
    required this.placement,
    required this.settings,
    required this.child,
    this.originalAspect = 1.0,
    this.selected = false,
    this.animatePosition = false,
    this.onPlacementChanged,
    this.onPlacementCommit,
    this.onSelectRequested,
  });

  final bool visible;
  final Size canvasSize;
  final CameraPlacement placement;
  final CameraSettings settings;
  final Widget child;
  final double originalAspect;
  final bool selected;

  /// When true, a CHANGE in [placement] springs the bubble to the new spot
  /// (250ms) instead of jumping — used for the alignment grid. The canvas
  /// passes false during drag and playback so those track immediately.
  final bool animatePosition;

  final ValueChanged<CameraPlacement>? onPlacementChanged;
  final VoidCallback? onPlacementCommit;
  final VoidCallback? onSelectRequested;

  @override
  State<AnimatedCameraBubble> createState() => _AnimatedCameraBubbleState();
}

class _AnimatedCameraBubbleState extends State<AnimatedCameraBubble>
    with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.visible ? 1.0 : 0.0,
  );
  late final CurvedAnimation _reveal = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  // Springy 250ms glide of the bubble's POSITION when it's set (e.g. the
  // alignment grid). easeOutBack overshoots slightly then settles → springy.
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 1.0,
  );
  late final CurvedAnimation _moveCurve =
      CurvedAnimation(parent: _move, curve: Curves.easeOutBack);
  late CameraPlacement _moveFrom = widget.placement;

  CameraPlacement get _displayedPlacement {
    if (!_move.isAnimating) return widget.placement;
    return _lerpPlacement(_moveFrom, widget.placement, _moveCurve.value);
  }

  @override
  void didUpdateWidget(AnimatedCameraBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      widget.visible ? _controller.forward() : _controller.reverse();
    }
    if (widget.placement != oldWidget.placement) {
      if (widget.animatePosition && widget.visible) {
        // Spring from wherever the bubble currently sits (handles interrupting
        // an in-flight glide) toward the new placement.
        _moveFrom = _move.isAnimating
            ? _lerpPlacement(_moveFrom, oldWidget.placement, _moveCurve.value)
            : oldWidget.placement;
        _move.forward(from: 0);
      } else {
        _move.value = 1.0; // snap (drag / playback track immediately)
      }
    }
  }

  @override
  void dispose() {
    _moveCurve.dispose();
    _move.dispose();
    _reveal.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_reveal, _move]),
      builder: (context, _) {
        final r = _reveal.value;
        if (!widget.visible && r <= 0.001) return const SizedBox.shrink();
        final interactive = widget.visible;
        return CameraBubble(
          canvasSize: widget.canvasSize,
          placement: _displayedPlacement,
          settings: widget.settings,
          originalAspect: widget.originalAspect,
          selected: interactive && widget.selected,
          onPlacementChanged: interactive ? widget.onPlacementChanged : null,
          onPlacementCommit: interactive ? widget.onPlacementCommit : null,
          onSelectRequested: interactive ? widget.onSelectRequested : null,
          reveal: r,
          child: widget.child,
        );
      },
    );
  }
}

CameraPlacement _lerpPlacement(CameraPlacement a, CameraPlacement b, double t) =>
    CameraPlacement(
      centerX: a.centerX + (b.centerX - a.centerX) * t,
      centerY: a.centerY + (b.centerY - a.centerY) * t,
      size: a.size + (b.size - a.size) * t,
    );
