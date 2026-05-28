import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A control wrapper that draws a springy "hover pill" behind [child].
///
/// All motion is driven by per-frame 2nd-order springs:
/// - hover-enter: the pill appears at the cursor's entry point and springs to
///   centre while growing in;
/// - hovering: it leans slightly toward the cursor (magnetic);
/// - press: it intensifies and shrinks, releasing back on tap-up;
/// - hover-exit: it flies toward the exit direction while shrinking + fading.
///
/// Tap handling and any [Key] are preserved, so existing finders/tests work.
class SpringHoverButton extends StatefulWidget {
  const SpringHoverButton({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = 9,
    this.onHoverChanged,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double borderRadius;

  /// Fires with true on hover-enter and false on hover-exit, so a control can
  /// animate its own content (e.g. brighten its icon/label) in step with the
  /// hover pill.
  final ValueChanged<bool>? onHoverChanged;

  @override
  State<SpringHoverButton> createState() => _SpringHoverButtonState();
}

/// A critically-tunable 1-D spring (zeta < 1 gives a springy overshoot).
class _Spring {
  _Spring(this.value, {required this.stiffness, required this.zeta})
      : target = value;

  double value;
  double velocity = 0;
  double target;
  final double stiffness;
  final double zeta;

  void tick(double dt) {
    final c = 2 * zeta * math.sqrt(stiffness);
    final a = -stiffness * (value - target) - c * velocity;
    velocity += a * dt;
    value += velocity * dt;
  }

  bool get settled =>
      (value - target).abs() < 0.0008 && velocity.abs() < 0.0008;
}

class _SpringHoverButtonState extends State<SpringHoverButton>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  final _reveal = _Spring(0, stiffness: 380, zeta: 1.0); // opacity 0..1 (quick fade)
  final _scale = _Spring(0.6, stiffness: 340, zeta: 0.6); // pill scale
  final _press = _Spring(0, stiffness: 520, zeta: 1.0); // press intensity 0..1
  final _dx = _Spring(0, stiffness: 300, zeta: 0.58); // offset from centre
  final _dy = _Spring(0, stiffness: 300, zeta: 0.58);
  // Inner-content parallax. The child (icon + text) tracks the cursor at a
  // smaller range than the pill, with a calmer spring (zeta 0.9 — no
  // perceptible overshoot), producing a "depth" effect: pill leans, child
  // settles. See docs/superpowers/specs/2026-05-28-parallax-hover-button-design.md.
  final _innerDx = _Spring(0, stiffness: 300, zeta: 0.9);
  final _innerDy = _Spring(0, stiffness: 300, zeta: 0.9);
  // 3D tilt of the child (icon + label as one rigid unit). Cursor-direction
  // drives small rotations about X (pitch) and Y (yaw), max ±6°, projected
  // through a 1/800 perspective. Same calm spring as the translate so the
  // tilt and the lean settle together.
  final _innerRotX = _Spring(0, stiffness: 300, zeta: 0.9);
  final _innerRotY = _Spring(0, stiffness: 300, zeta: 0.9);
  // The visible 2D edge-shift of a 3D tilt is ~ halfWidth² · sin(angle) ·
  // perspective. To make all bar buttons read as equally tilted regardless
  // of size, we scale perspective inversely with the button's halfWidth so
  // perspective · halfWidth stays constant — making the FRACTIONAL shift
  // (shift / halfWidth) constant across all sizes. _kPerspectiveScale is
  // calibrated so a ~67px-halfWidth chip (the widest one in the bar) uses
  // 1/180 (the value that read well by eye). A safety cap at 1/50 keeps the
  // smallest buttons from looking distorted.
  static const double _kMaxTiltRadians = 10 * math.pi / 180;
  static const double _kPerspectiveScale = 67.0 / 180.0; // ≈ 0.372
  static const double _kMaxPerspective = 1 / 50;
  static const double _kFallbackPerspective = 1 / 180;

  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _ensureTicking() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : math.min((elapsed - _last).inMicroseconds / 1e6, 1 / 30);
    _last = elapsed;
    for (final s in [
      _reveal,
      _scale,
      _press,
      _dx,
      _dy,
      _innerDx,
      _innerDy,
      _innerRotX,
      _innerRotY,
    ]) {
      s.tick(dt);
    }
    setState(() {});
    if (_reveal.settled &&
        _scale.settled &&
        _press.settled &&
        _dx.settled &&
        _dy.settled &&
        _innerDx.settled &&
        _innerDy.settled &&
        _innerRotX.settled &&
        _innerRotY.settled) {
      _ticker.stop();
    }
  }

  Size get _size =>
      (context.findRenderObject() as RenderBox?)?.size ?? Size.zero;

  Offset _centreRel(Offset local) {
    final s = _size;
    return Offset(local.dx - s.width / 2, local.dy - s.height / 2);
  }

  void _onEnter(PointerEnterEvent e) {
    _hovering = true;
    widget.onHoverChanged?.call(true);
    final rel = _centreRel(e.localPosition);
    _dx.value = rel.dx; // start where the cursor entered
    _dy.value = rel.dy;
    _dx.target = (rel.dx * 0.12).clamp(-8.0, 8.0); // small magnetic lean
    _dy.target = (rel.dy * 0.12).clamp(-6.0, 6.0);
    // Inner-content parallax: ~25% of the pill's range, calmer spring. The
    // child does NOT start at the cursor like the pill does — it stays at
    // its layout position and springs into the (small) parallax offset.
    // Inner translate paused while iterating on the tilt alone.
    _innerDx.target = 0;
    _innerDy.target = 0;
    // 3D tilt of the icon+label as one unit. Cursor in the top-right → top-right
    // edge of the button comes toward the viewer (rotateX with cursor below
    // centre → bottom forward; rotateY with cursor to the right → right
    // forward), so the surface "tilts toward the cursor."
    _setTiltTargets(rel);
    _reveal.target = 1;
    _scale.value = 0.6;
    _scale.target = 1;
    _ensureTicking();
  }

  void _onHover(PointerHoverEvent e) {
    if (!_hovering) return;
    final rel = _centreRel(e.localPosition);
    _dx.target = (rel.dx * 0.12).clamp(-8.0, 8.0);
    _dy.target = (rel.dy * 0.12).clamp(-6.0, 6.0);
    // Inner translate paused while iterating on the tilt alone.
    _innerDx.target = 0;
    _innerDy.target = 0;
    _setTiltTargets(rel);
    _ensureTicking();
  }

  /// Drives [_innerRotX]/[_innerRotY] toward a "tilt-toward-cursor" pose.
  /// `rel` is centre-relative pointer position; the button's half-size
  /// normalizes the input so a full edge-of-button hover hits the ±6° clamp.
  void _setTiltTargets(Offset rel) {
    final s = _size;
    final halfW = s.width / 2;
    final halfH = s.height / 2;
    // rotateX: positive angle tilts the bottom edge toward the viewer in
    // Flutter's screen-down-Y frame. Cursor below centre (rel.dy > 0) → tilt
    // bottom forward → positive rotX.
    _innerRotX.target = halfH == 0
        ? 0
        : ((rel.dy / halfH) * _kMaxTiltRadians)
            .clamp(-_kMaxTiltRadians, _kMaxTiltRadians);
    // rotateY: positive angle in this frame tilts the LEFT edge toward the
    // viewer; we want the RIGHT edge forward when the cursor is to the right,
    // so negate.
    _innerRotY.target = halfW == 0
        ? 0
        : (-(rel.dx / halfW) * _kMaxTiltRadians)
            .clamp(-_kMaxTiltRadians, _kMaxTiltRadians);
  }

  void _onExit(PointerExitEvent e) {
    _hovering = false;
    widget.onHoverChanged?.call(false);
    final rel = _centreRel(e.localPosition);
    final dist = rel.distance;
    final dir = dist == 0 ? const Offset(0, -1) : rel / dist;
    final s = _size;
    _dx.target = dir.dx * (s.width * 0.5 + 14);
    _dy.target = dir.dy * (s.height * 0.5 + 14);
    // Child glides home + untilts — only the pill flies off on exit.
    _innerDx.target = 0;
    _innerDy.target = 0;
    _innerRotX.target = 0;
    _innerRotY.target = 0;
    _reveal.target = 0;
    // Barely shrink on the way out — the fade carries the vanish, so the pill
    // never reads as a tiny scaled-down dot.
    _scale.target = 0.82;
    _press.target = 0;
    _ensureTicking();
  }

  void _onTapDown(TapDownDetails _) {
    _press.target = 1;
    _scale.target = 0.88;
    _ensureTicking();
  }

  void _release() {
    _press.target = 0;
    _scale.target = _hovering ? 1 : 0.82;
    _ensureTicking();
  }

  @override
  Widget build(BuildContext context) {
    final reveal = _reveal.value.clamp(0.0, 1.0);
    final tappable = widget.onTap != null;
    // Per-button-size perspective so all tilts feel equally 3D (see comment
    // on _kPerspectiveScale). Falls back to the calibration value on the
    // first build before layout (when _size is zero).
    final halfW = _size.width / 2;
    final perspective = halfW > 0
        ? math.min(_kPerspectiveScale / halfW, _kMaxPerspective)
        : _kFallbackPerspective;
    return MouseRegion(
      onEnter: _onEnter,
      onHover: _onHover,
      onExit: _onExit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: tappable ? _onTapDown : null,
        onTapUp: tappable ? (_) => _release() : null,
        onTapCancel: tappable ? _release : null,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: reveal,
                  child: Transform.translate(
                    offset: Offset(_dx.value, _dy.value),
                    child: Transform.scale(
                      scale: _scale.value.clamp(0.0, 1.2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: (0.07 + 0.12 * _press.value).clamp(0.0, 0.22),
                          ),
                          borderRadius:
                              BorderRadius.circular(widget.borderRadius),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(_innerDx.value, _innerDy.value),
              // Icon + label tilt as ONE rigid unit, centred on the child's
              // bounding box. Perspective makes it read as 3D rather than a 2D
              // skew. FilterQuality.high keeps the receding edge of the label
              // from getting pixelated at the tilt angle.
              // Note: NO `filterQuality` here. Setting it forces Flutter to
              // raster the child to an offscreen image before sampling, which
              // visibly drops small font glyphs (the bar gear's settings icon
              // would vanish on hover) at non-identity perspective. The
              // default tree-walked transform draws fonts directly and keeps
              // them crisp through the tilt.
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, perspective)
                  ..rotateX(_innerRotX.value)
                  ..rotateY(_innerRotY.value),
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
