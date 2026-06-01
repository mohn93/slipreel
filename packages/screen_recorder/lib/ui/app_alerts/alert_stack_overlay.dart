import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/app_alerts/alert_pill.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

/// Reads [AppAlertsController.stack] and renders a shadcn/Sonner-style
/// alert deck at top-center.
///
/// Default state: the newest alert is full-size at the front; older
/// alerts sit behind it, slightly scaled down and offset downward so
/// they peek out. Hovering or clicking the deck fans the alerts into a
/// vertical column at full size, and pauses every alert's
/// auto-dismiss timer until the cursor leaves (or another click
/// re-collapses).
class AlertStackOverlay extends StatefulWidget {
  const AlertStackOverlay({super.key, required this.controller});

  final AppAlertsController controller;

  @override
  State<AlertStackOverlay> createState() => _AlertStackOverlayState();
}

class _AlertStackOverlayState extends State<AlertStackOverlay> {
  bool _expanded = false;
  List<AlertEntry> _lastStack = const [];

  // Approximate pill height (chrome + 14px text). Used to compute the
  // container's height and per-pill offsets. Exact text height varies
  // slightly with wrapping but the deck stays well-aligned because each
  // pill paints its own intrinsic size; this constant only controls
  // layout box and offset math, not the pill itself.
  static const double _kPillHeight = 52;
  static const double _kGap = 8;
  static const double _kCollapsedPeek = 8;
  static const double _kCollapsedScaleStep = 0.05;
  static const Duration _kMotion = Duration(milliseconds: 280);
  static const Curve _kCurve = Curves.easeOutQuint;

  void _setExpanded(bool value) {
    if (_expanded == value) return;
    setState(() => _expanded = value);
    // Pause every live timer when expanded; resume when collapsed.
    // Skip sticky entries — pauseTimer/resumeTimer are no-ops on them.
    for (final entry in _lastStack) {
      if (value) {
        widget.controller.pauseTimer(entry);
      } else {
        widget.controller.resumeTimer(entry);
      }
    }
  }

  double _dyFor(int depth) {
    if (_expanded) return depth * (_kPillHeight + _kGap);
    return depth * _kCollapsedPeek;
  }

  double _scaleFor(int depth) {
    if (_expanded) return 1.0;
    return math.max(0.85, 1 - depth * _kCollapsedScaleStep);
  }

  double _opacityFor(int depth) {
    if (_expanded) return 1.0;
    return math.max(0.6, 1 - depth * 0.15);
  }

  double _heightFor(int n) {
    if (n == 0) return 0;
    if (_expanded) return n * _kPillHeight + (n - 1) * _kGap;
    return _kPillHeight + (n - 1) * _kCollapsedPeek;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      // type: transparency gives a sane DefaultTextStyle ancestor without
      // painting a background, killing the red-underlined "no theme"
      // fallback that bare overlays inherit.
      type: MaterialType.transparency,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: ValueListenableBuilder<List<AlertEntry>>(
              valueListenable: widget.controller.stack,
              builder: (context, stack, _) {
                _lastStack = stack;
                if (stack.isEmpty) return const SizedBox.shrink();

                // Newest first → depth 0 is the front-most pill.
                final reversed = stack.reversed.toList();
                final n = reversed.length;

                return MouseRegion(
                  onEnter: (_) => _setExpanded(true),
                  onExit: (_) => _setExpanded(false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _setExpanded(!_expanded),
                    child: AnimatedContainer(
                      duration: _kMotion,
                      curve: _kCurve,
                      width: 560,
                      height: _heightFor(n),
                      child: Stack(
                        alignment: Alignment.topCenter,
                        clipBehavior: Clip.none,
                        children: [
                          // Render back-to-front so the newest pill paints
                          // on top of the older ones in the collapsed deck.
                          for (var i = n - 1; i >= 0; i--)
                            AnimatedPositioned(
                              key: reversed[i].key,
                              duration: _kMotion,
                              curve: _kCurve,
                              top: _dyFor(i),
                              left: 0,
                              right: 0,
                              child: AnimatedScale(
                                duration: _kMotion,
                                curve: _kCurve,
                                alignment: Alignment.topCenter,
                                scale: _scaleFor(i),
                                child: AnimatedOpacity(
                                  duration: _kMotion,
                                  curve: _kCurve,
                                  opacity: _opacityFor(i),
                                  child: Center(
                                    child: _EnteringPill(
                                      entry: reversed[i],
                                      controller: widget.controller,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Plays a one-shot enter animation (slide down + fade in) the FIRST
/// time the pill is mounted. Subsequent layout changes (depth/scale
/// when a newer pill arrives, or the expand transition) are handled by
/// the parent's implicit animations — this widget only owns the
/// initial entry.
class _EnteringPill extends StatefulWidget {
  const _EnteringPill({required this.entry, required this.controller});

  final AlertEntry entry;
  final AppAlertsController controller;

  @override
  State<_EnteringPill> createState() => _EnteringPillState();
}

class _EnteringPillState extends State<_EnteringPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..forward();

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -0.6),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ac, curve: Curves.easeOutQuint));

  late final Animation<double> _fade =
      CurvedAnimation(parent: _ac, curve: Curves.easeOutQuint);

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: AlertPill(
          entry: widget.entry,
          onDismiss: () => widget.controller.dismiss(widget.entry),
          // Per-pill hover is intentionally a no-op now: the outer
          // MouseRegion handles the expand+pause-all behavior, and per-
          // pill pause/resume would race with that.
          onHoverEnter: () {},
          onHoverExit: () {},
        ),
      ),
    );
  }
}
