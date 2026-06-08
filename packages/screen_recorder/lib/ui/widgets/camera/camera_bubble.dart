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

  Rect _pixelBox() {
    final w = placement.size * canvasSize.width;
    final aspect = settings.shape.pixelAspect(originalAspect);
    final h = w / aspect;
    // Keep the box fully on the canvas with edge padding — the camera can never
    // go out of view (or sit flush against the frame), regardless of what
    // center was stored (drag, grid, or seed). If it's larger than the padded
    // canvas on an axis, center it there.
    final padX = kCameraEdgeMargin * canvasSize.width;
    final padY = kCameraEdgeMargin * canvasSize.height;
    final loX = w / 2 + padX, hiX = canvasSize.width - w / 2 - padX;
    final loY = h / 2 + padY, hiY = canvasSize.height - h / 2 - padY;
    final cx = loX <= hiX
        ? (placement.centerX * canvasSize.width).clamp(loX, hiX).toDouble()
        : canvasSize.width / 2;
    final cy = loY <= hiY
        ? (placement.centerY * canvasSize.height).clamp(loY, hiY).toDouble()
        : canvasSize.height / 2;
    return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
  }


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
                  // the inspector + handles follow.
                  GestureDetector(
                    key: const Key('camera-move-body'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onSelectRequested,
                    onPanStart: (_) => onSelectRequested?.call(),
                    onPanUpdate: (d) => _moveBy(d.delta),
                    onPanEnd: (_) => onPlacementCommit?.call(),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.move,
                      child: bubble,
                    ),
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

  void _moveBy(Offset deltaPx) {
    final cb = onPlacementChanged;
    if (cb == null) return;
    final rawX = placement.centerX + deltaPx.dx / canvasSize.width;
    final rawY = placement.centerY + deltaPx.dy / canvasSize.height;
    final shapeAspect = settings.shape.pixelAspect(originalAspect);
    final double nx, ny;
    if (HardwareKeyboard.instance.isAltPressed) {
      // Free move — no anchor snap, but still kept fully in view.
      final ca =
          canvasSize.height == 0 ? 1.0 : canvasSize.width / canvasSize.height;
      final ext = cameraHalfExtents(
          size: placement.size, shapeAspect: shapeAspect, canvasAspect: ca);
      final c = clampCameraCenterInView(
          centerX: rawX, centerY: rawY, halfW: ext.halfW, halfH: ext.halfH);
      nx = c.cx;
      ny = c.cy;
    } else {
      final snap = snapCameraCenter(
        centerX: rawX,
        centerY: rawY,
        canvasSize: canvasSize,
        size: placement.size,
        shapeAspect: shapeAspect,
      );
      nx = snap.center.dx;
      ny = snap.center.dy;
    }
    cb(CameraPlacement(centerX: nx, centerY: ny, size: placement.size));
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
  final ValueChanged<CameraPlacement>? onPlacementChanged;
  final VoidCallback? onPlacementCommit;
  final VoidCallback? onSelectRequested;

  @override
  State<AnimatedCameraBubble> createState() => _AnimatedCameraBubbleState();
}

class _AnimatedCameraBubbleState extends State<AnimatedCameraBubble>
    with SingleTickerProviderStateMixin {
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

  @override
  void didUpdateWidget(AnimatedCameraBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      widget.visible ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, _) {
        final r = _reveal.value;
        if (!widget.visible && r <= 0.001) return const SizedBox.shrink();
        final interactive = widget.visible;
        return CameraBubble(
          canvasSize: widget.canvasSize,
          placement: widget.placement,
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
