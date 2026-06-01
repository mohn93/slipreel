import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/app_alerts/alert_pill.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

/// Reads [AppAlertsController.stack] and renders a top-center vertical
/// column of [AlertPill]s with entry/exit animations.
///
/// Hover on a pill pauses its controller-side auto-dismiss timer; mouse
/// leave resumes it. Tap on a pill (or its action button) dismisses
/// via the controller.
class AlertStackOverlay extends StatelessWidget {
  const AlertStackOverlay({super.key, required this.controller});

  final AppAlertsController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: ValueListenableBuilder<List<AlertEntry>>(
            valueListenable: controller.stack,
            builder: (context, stack, _) {
              return AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in stack) ...[
                      _AnimatedPill(
                        key: entry.key,
                        entry: entry,
                        controller: controller,
                      ),
                      if (entry != stack.last) const SizedBox(height: 8),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Wraps [AlertPill] with the enter slide+fade animation. Exit
/// animation is handled by the parent stack removing the entry — the
/// AnimatedSize collapses the row and the GC handles teardown.
class _AnimatedPill extends StatefulWidget {
  const _AnimatedPill({
    super.key,
    required this.entry,
    required this.controller,
  });

  final AlertEntry entry;
  final AppAlertsController controller;

  @override
  State<_AnimatedPill> createState() => _AnimatedPillState();
}

class _AnimatedPillState extends State<_AnimatedPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1.2),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic));

  late final Animation<double> _fade =
      CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic);

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
          onHoverEnter: () => widget.controller.pauseTimer(widget.entry),
          onHoverExit: () => widget.controller.resumeTimer(widget.entry),
        ),
      ),
    );
  }
}
