import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

/// One floating alert pill. Pure widget — animation lifecycle is owned
/// by [AlertStackOverlay] via [AnimatedSwitcher] / `key`-driven mount
/// and unmount. This widget is responsible for: chrome, layout,
/// hover-pause callbacks, click-to-dismiss, and the optional action
/// button.
class AlertPill extends StatelessWidget {
  const AlertPill({
    super.key,
    required this.entry,
    required this.onDismiss,
    required this.onHoverEnter,
    required this.onHoverExit,
  });

  final AlertEntry entry;
  final VoidCallback onDismiss;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;

  @override
  Widget build(BuildContext context) {
    final action = entry.action;
    return MouseRegion(
      onEnter: (_) => onHoverEnter(),
      onExit: (_) => onHoverExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: action == null ? onDismiss : null,
        // When an action button is present we keep the body tap-to-dismiss
        // behavior for clicks outside the button; nested GestureDetector on
        // the button stops propagation.
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 240,
            maxWidth: 560,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF000000).withValues(alpha: 0.92),
              border: Border.all(
                color: const Color(0xFFFFFFFF).withValues(alpha: 0.08),
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.45),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.type.icon, size: 20, color: entry.type.accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      entry.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (action != null) ...[
                    const SizedBox(width: 12),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        action.onPressed();
                        onDismiss();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          action.label,
                          style: TextStyle(
                            color: entry.type.accent,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
