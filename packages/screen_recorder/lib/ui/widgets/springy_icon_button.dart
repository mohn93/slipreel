import 'dart:async';

import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Reusable icon button used by the side rails. Delegates the
/// hover/press feedback (springy pill + magnetic lean + 3D tilt) to
/// [SpringHoverButton] — the same physics the recording bar uses —
/// and layers the rail-specific "active" tint + accent icon color +
/// left-side tooltip on top. Keeping the recording bar's spring math
/// in one place means all hover affordances across the app feel
/// identical.
/// Which side of the button its tooltip pops out on. Side rails sit
/// on the right edge of the editor and want their tooltips to the
/// LEFT so they don't fly off-screen; top-bar chips want them BELOW
/// so they don't collide with the title row above.
enum SpringyTooltipPlacement { left, bottom }

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
    this.tooltipPlacement = SpringyTooltipPlacement.left,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;

  /// When false the tap is a no-op and the icon dims, but hover
  /// motion still plays so the button feels alive — the caller is
  /// expected to provide a tooltip explaining why it's disabled.
  final bool isEnabled;
  final double size;
  final double iconSize;
  final SpringyTooltipPlacement tooltipPlacement;

  @override
  State<SpringyIconButton> createState() => _SpringyIconButtonState();
}

class _SpringyIconButtonState extends State<SpringyIconButton> {
  final LayerLink _link = LayerLink();
  final GlobalKey<_HoverTooltipState> _tooltipKey =
      GlobalKey<_HoverTooltipState>();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final Color iconColor;
    if (!widget.isEnabled) {
      iconColor = palette.textSecondary.withValues(alpha: 0.35);
    } else if (widget.isActive) {
      iconColor = palette.accent;
    } else {
      iconColor = palette.textSecondary;
    }
    final bgColor = widget.isActive
        ? palette.accent.withValues(alpha: 0.18)
        : Colors.transparent;

    // Outer MouseRegion (independent of SpringHoverButton's own
    // MouseRegion) just gates the left tooltip's open/close timer.
    // The two regions don't interfere — onEnter/onExit fire on each
    // independently.
    return _HoverTooltip(
      key: _tooltipKey,
      link: _link,
      message: widget.tooltip,
      placement: widget.tooltipPlacement,
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) => _tooltipKey.currentState?.scheduleShow(),
          onExit: (_) => _tooltipKey.currentState?.cancel(),
          child: SpringHoverButton(
            onTap: widget.isEnabled ? widget.onTap : null,
            borderRadius: 10,
            onHoverChanged: (hovering) {
              // Cancel the tooltip the moment the spring takes over a
              // press — mirrors the recording bar's behavior.
              if (!hovering) _tooltipKey.currentState?.cancel();
            },
            child: Container(
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
          ),
        ),
      ),
    );
  }
}

/// Tooltip that pops to the [placement] side of its child after a
/// hover delay. Owns its own [OverlayEntry] lifecycle; parent
/// triggers [scheduleShow]/[cancel] via the [GlobalKey].
class _HoverTooltip extends StatefulWidget {
  const _HoverTooltip({
    super.key,
    required this.link,
    required this.message,
    required this.child,
    required this.placement,
  });


  final LayerLink link;
  final String message;
  final Widget child;
  final SpringyTooltipPlacement placement;
  static const Duration _delay = Duration(milliseconds: 500);

  @override
  State<_HoverTooltip> createState() => _HoverTooltipState();
}

class _HoverTooltipState extends State<_HoverTooltip> {
  Timer? _showTimer;
  OverlayEntry? _entry;

  void scheduleShow() {
    _showTimer?.cancel();
    _showTimer = Timer(_HoverTooltip._delay, _show);
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
    final palette = context.palette;
    // Place the tooltip's anchor relative to the button — `left`
    // pops it off the button's left edge (used by the right-side
    // rails so the popup doesn't fly off-screen); `bottom` drops it
    // straight under the button (used by top-bar chips so it can't
    // collide with the title row above).
    final Alignment target;
    final Alignment follower;
    final Offset offset;
    switch (widget.placement) {
      case SpringyTooltipPlacement.left:
        target = Alignment.centerLeft;
        follower = Alignment.centerRight;
        offset = const Offset(-8, 0);
        break;
      case SpringyTooltipPlacement.bottom:
        target = Alignment.bottomCenter;
        follower = Alignment.topCenter;
        offset = const Offset(0, 8);
        break;
    }
    final entry = OverlayEntry(builder: (ctx) {
      return Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: widget.link,
          targetAnchor: target,
          followerAnchor: follower,
          offset: offset,
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
