import 'dart:async';

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
    this.isEnabled = true,
    this.size = 40,
    this.iconSize = 20,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;

  /// When false the tap is a no-op, the press scale is suppressed,
  /// and the hover background tint is dimmer. Tooltip + hover scale
  /// still play so the button feels alive — the caller is expected
  /// to provide a tooltip explaining why the button is disabled.
  final bool isEnabled;
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

  final LayerLink _link = LayerLink();
  final GlobalKey<_LeftTooltipState> _tooltipKey = GlobalKey<_LeftTooltipState>();

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
    final Color iconColor;
    if (!widget.isEnabled) {
      // Visibly muted so disabled tabs read as unavailable at a glance.
      iconColor = palette.textSecondary.withValues(alpha: 0.35);
    } else if (widget.isActive) {
      iconColor = palette.accent;
    } else {
      iconColor = palette.textSecondary;
    }
    final bgColor = _backgroundColor(palette);

    return _LeftTooltip(
      key: _tooltipKey,
      link: _link,
      message: widget.tooltip,
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) {
            setState(() => _hovered = true);
            _animateToTarget();
            _tooltipKey.currentState?.scheduleShow();
          },
          onExit: (_) {
            setState(() {
              _hovered = false;
              _pressed = false;
            });
            _animateToTarget();
            _tooltipKey.currentState?.cancel();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: widget.isEnabled
                ? (_) {
                    setState(() => _pressed = true);
                    _animateToTarget();
                    _tooltipKey.currentState?.cancel();
                  }
                : null,
            onTapUp: widget.isEnabled
                ? (_) {
                    setState(() => _pressed = false);
                    _animateToTarget();
                  }
                : null,
            onTapCancel: widget.isEnabled
                ? () {
                    setState(() => _pressed = false);
                    _animateToTarget();
                  }
                : null,
            onTap: widget.isEnabled ? widget.onTap : null,
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
        ),
      ),
    );
  }

  Color _backgroundColor(AppPalette palette) {
    // Base alpha is whatever AppPalette.accentMuted encodes (~0.18).
    // Disabled: 0 at rest; 0.45× at hover (dimmer than enabled).
    // Inactive: 0 at rest; 0.85× at hover/press.
    // Active: 1.0× at rest; 1.3× at hover/press.
    final hovering = _hovered || _pressed;
    final double alphaMultiplier;
    if (!widget.isEnabled) {
      alphaMultiplier = hovering ? 0.45 : 0.0;
    } else if (widget.isActive) {
      alphaMultiplier = hovering ? 1.3 : 1.0;
    } else {
      alphaMultiplier = hovering ? 0.85 : 0.0;
    }
    if (alphaMultiplier == 0.0) return Colors.transparent;
    return palette.accent.withValues(alpha: 0.18 * alphaMultiplier);
  }
}

/// Tooltip that pops to the LEFT of its child after a hover delay.
/// Owns its own [OverlayEntry] lifecycle; parent triggers
/// [scheduleShow]/[cancel] via the [GlobalKey].
class _LeftTooltip extends StatefulWidget {
  const _LeftTooltip({
    super.key,
    required this.link,
    required this.message,
    required this.child,
    this.delay = const Duration(milliseconds: 500),
  });

  final LayerLink link;
  final String message;
  final Widget child;
  final Duration delay;

  @override
  State<_LeftTooltip> createState() => _LeftTooltipState();
}

class _LeftTooltipState extends State<_LeftTooltip> {
  Timer? _showTimer;
  OverlayEntry? _entry;

  void scheduleShow() {
    _showTimer?.cancel();
    _showTimer = Timer(widget.delay, _show);
  }

  void cancel() {
    _showTimer?.cancel();
    _showTimer = null;
    _entry?.remove();
    _entry = null;
  }

  void _show() {
    if (_entry != null) return;
    final overlay = Overlay.of(context);
    // Capture palette from host context before entering the overlay's context.
    final palette = context.palette;
    final entry = OverlayEntry(builder: (ctx) {
      return Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: widget.link,
          targetAnchor: Alignment.centerLeft,
          followerAnchor: Alignment.centerRight,
          offset: const Offset(-8, 0),
          showWhenUnlinked: false,
          child: AnimatedOpacity(
            opacity: 1,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: palette.surfaceCard,
                  border: Border.all(color: palette.dividerSubtle),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.message,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
    overlay.insert(entry);
    _entry = entry;
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
