import 'package:flutter/material.dart';

import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
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
  });

  /// The canvas (`totalSize`) this bubble is positioned within.
  final Size canvasSize;
  final CameraPlacement placement;
  final CameraSettings settings;

  /// The camera source's width/height; used only when shape == original.
  final double originalAspect;

  final Widget child;
  final bool selected;

  /// When non-null and [selected], the bubble is editable; called with the
  /// new normalized placement during drag/resize.
  final ValueChanged<CameraPlacement>? onPlacementChanged;

  static const double _minSize = 0.05;
  static const double _maxSize = 1.2;

  Rect _pixelBox() {
    final w = (placement.size * canvasSize.width);
    final aspect = settings.shape.pixelAspect(originalAspect);
    final h = w / aspect;
    final cx = placement.centerX * canvasSize.width;
    final cy = placement.centerY * canvasSize.height;
    return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
  }

  bool get _editable => selected && onPlacementChanged != null;

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
      opacity: settings.opacity.clamp(0.0, 1.0),
      child: decorated,
    );

    if (_editable) {
      bubble = _withEditAffordances(bubble, box);
    }

    // Self-contained: the bubble fills the canvas and positions its box in an
    // internal Stack, so it can be dropped straight into PlaybackCanvas (or a
    // test) without the caller providing a Stack.
    return SizedBox(
      width: canvasSize.width,
      height: canvasSize.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: box.left, top: box.top, child: bubble),
        ],
      ),
    );
  }

  Widget _clipped(Widget c) {
    final fitted = FittedBox(fit: BoxFit.cover, child: c);
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

  Widget _withEditAffordances(Widget bubble, Rect box) {
    const handle = 16.0;
    Widget cornerHandle(String id, Alignment a) => Positioned(
          left: a.x < 0 ? -handle / 2 : null,
          right: a.x > 0 ? -handle / 2 : null,
          top: a.y < 0 ? -handle / 2 : null,
          bottom: a.y > 0 ? -handle / 2 : null,
          child: GestureDetector(
            key: Key('camera-handle-$id'),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => _resizeBy(d.delta, a),
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

    return SizedBox(
      width: box.width,
      height: box.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Move handle = the body.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => _moveBy(d.delta),
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: bubble,
            ),
          ),
          // A thin selection ring for affordance.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape:
                      settings.shape.isRound ? BoxShape.circle : BoxShape.rectangle,
                  border: Border.all(color: const Color(0xFF6C63FF), width: 1.5),
                ),
              ),
            ),
          ),
          cornerHandle('tl', Alignment.topLeft),
          cornerHandle('tr', Alignment.topRight),
          cornerHandle('bl', Alignment.bottomLeft),
          cornerHandle('br', Alignment.bottomRight),
        ],
      ),
    );
  }

  void _moveBy(Offset deltaPx) {
    final cb = onPlacementChanged;
    if (cb == null) return;
    final dx = deltaPx.dx / canvasSize.width;
    final dy = deltaPx.dy / canvasSize.height;
    cb(CameraPlacement(
      centerX: (placement.centerX + dx).clamp(0.0, 1.0),
      centerY: (placement.centerY + dy).clamp(0.0, 1.0),
      size: placement.size,
    ));
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
