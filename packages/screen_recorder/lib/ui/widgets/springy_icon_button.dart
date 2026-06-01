import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Reusable icon button with a spring-physics hover/press response.
/// "Active" buttons retain a held-down look (tinted background +
/// accent icon color) — the spring response is layered on top of that
/// for hover and press confirmation.
class SpringyIconButton extends StatefulWidget {
  const SpringyIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.onTap,
    this.size = 40,
    this.iconSize = 20,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;
  final double size;
  final double iconSize;

  @override
  State<SpringyIconButton> createState() => _SpringyIconButtonState();
}

class _SpringyIconButtonState extends State<SpringyIconButton>
    with SingleTickerProviderStateMixin {
  static const _spring = SpringDescription(
    mass: 1.0,
    stiffness: 220.0,
    damping: 16.0,
  );

  late final AnimationController _scaleAc = AnimationController.unbounded(
    vsync: this,
    value: 1.0,
  );

  bool _hovered = false;
  bool _pressed = false;

  @override
  void dispose() {
    _scaleAc.dispose();
    super.dispose();
  }

  double get _restScale => 1.0;
  double get _hoverScale => widget.isActive ? 1.04 : 1.08;
  double get _pressScale => 0.94;

  double get _targetScale {
    if (_pressed) return _pressScale;
    if (_hovered) return _hoverScale;
    return _restScale;
  }

  void _animateToTarget() {
    final sim = SpringSimulation(
        _spring, _scaleAc.value, _targetScale, _scaleAc.velocity);
    _scaleAc.animateWith(sim);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final iconColor =
        widget.isActive ? palette.accent : palette.textSecondary;
    final bgColor = _backgroundColor(palette);

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        _animateToTarget();
      },
      onExit: (_) {
        setState(() {
          _hovered = false;
          _pressed = false;
        });
        _animateToTarget();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          setState(() => _pressed = true);
          _animateToTarget();
        },
        onTapUp: (_) {
          setState(() => _pressed = false);
          _animateToTarget();
        },
        onTapCancel: () {
          setState(() => _pressed = false);
          _animateToTarget();
        },
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _scaleAc,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: iconColor,
            ),
          ),
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAc.value,
              child: child,
            );
          },
        ),
      ),
    );
  }

  Color _backgroundColor(AppPalette palette) {
    // Base alpha is whatever AppPalette.accentMuted encodes (~0.18).
    // Inactive: 0 (transparent) at rest; 0.4× at hover/press.
    // Active: 1.0× at rest; 1.1× at hover/press.
    // We compose by alpha-scaling the accent color.
    final hovering = _hovered || _pressed;
    final double alphaMultiplier;
    if (widget.isActive) {
      alphaMultiplier = hovering ? 1.1 : 1.0;
    } else {
      alphaMultiplier = hovering ? 0.4 : 0.0;
    }
    if (alphaMultiplier == 0.0) return Colors.transparent;
    return palette.accent.withValues(alpha: 0.18 * alphaMultiplier);
  }
}
