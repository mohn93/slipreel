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
  });

  final Widget child;
  final VoidCallback? onTap;
  final double borderRadius;

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

  final _reveal = _Spring(0, stiffness: 240, zeta: 1.0); // opacity 0..1
  final _scale = _Spring(0.6, stiffness: 340, zeta: 0.6); // pill scale
  final _press = _Spring(0, stiffness: 520, zeta: 1.0); // press intensity 0..1
  final _dx = _Spring(0, stiffness: 300, zeta: 0.58); // offset from centre
  final _dy = _Spring(0, stiffness: 300, zeta: 0.58);

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
    for (final s in [_reveal, _scale, _press, _dx, _dy]) {
      s.tick(dt);
    }
    setState(() {});
    if (_reveal.settled &&
        _scale.settled &&
        _press.settled &&
        _dx.settled &&
        _dy.settled) {
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
    final rel = _centreRel(e.localPosition);
    _dx.value = rel.dx; // start where the cursor entered
    _dy.value = rel.dy;
    _dx.target = (rel.dx * 0.12).clamp(-8.0, 8.0); // small magnetic lean
    _dy.target = (rel.dy * 0.12).clamp(-6.0, 6.0);
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
    _ensureTicking();
  }

  void _onExit(PointerExitEvent e) {
    _hovering = false;
    final rel = _centreRel(e.localPosition);
    final dist = rel.distance;
    final dir = dist == 0 ? const Offset(0, -1) : rel / dist;
    final s = _size;
    _dx.target = dir.dx * (s.width * 0.5 + 14);
    _dy.target = dir.dy * (s.height * 0.5 + 14);
    _reveal.target = 0;
    _scale.target = 0.4;
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
    _scale.target = _hovering ? 1 : 0.4;
    _ensureTicking();
  }

  @override
  Widget build(BuildContext context) {
    final reveal = _reveal.value.clamp(0.0, 1.0);
    final tappable = widget.onTap != null;
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
                            alpha: (0.12 + 0.16 * _press.value).clamp(0.0, 0.34),
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
            widget.child,
          ],
        ),
      ),
    );
  }
}
