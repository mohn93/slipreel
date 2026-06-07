import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/bar/spring_hover_button.dart';

/// Skip-back / skip-forward button used in the transport bar above the
/// timeline. Wraps the icon in [SpringHoverButton] for the standard
/// spring-physics hover treatment (magnetic lean toward the cursor,
/// soft press-shrink, pill reveal) used everywhere else in the
/// inspector and the bar. Rich tooltip preserved — the spring is the
/// only thing that changed.
class TransportButton extends StatelessWidget {
  const TransportButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.shortcut,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final String shortcut;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      richMessage: TextSpan(
        children: [
          TextSpan(
            text: tooltip,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const TextSpan(text: '   '),
          TextSpan(
            text: shortcut,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A26),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF35354A)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      verticalOffset: 22,
      child: SpringHoverButton(
        onTap: onPressed,
        borderRadius: 10,
        // SpringHoverButton paints its own reveal pill on hover, so
        // we don't carry a manual `_hovered` background like before —
        // the child stays transparent and the spring handles the
        // visual.
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Circular outlined play/pause button shown between the skip buttons
/// in the transport bar. Same [SpringHoverButton] treatment as
/// [TransportButton] — the spring is the only thing that changed; the
/// outlined ring (which is THIS button's identity) is still painted on
/// every state and brightens on hover.
class TransportPlayButton extends StatefulWidget {
  const TransportPlayButton({
    super.key,
    required this.isPlaying,
    required this.onPressed,
  });

  final bool isPlaying;
  final VoidCallback onPressed;

  @override
  State<TransportPlayButton> createState() => _TransportPlayButtonState();
}

class _TransportPlayButtonState extends State<TransportPlayButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      richMessage: TextSpan(
        children: [
          TextSpan(
            text: widget.isPlaying ? 'Pause' : 'Play',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const TextSpan(text: '   '),
          const TextSpan(
            text: 'Space',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A26),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF35354A)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      verticalOffset: 26,
      child: SpringHoverButton(
        onTap: widget.onPressed,
        // Half of the 44 px box → the reveal pill renders as a
        // circle, matching the outlined ring.
        borderRadius: 22,
        onHoverChanged: (h) => setState(() => _hovered = h),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: _hovered ? Colors.white : Colors.white70,
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            widget.isPlaying ? Icons.pause : Icons.play_arrow,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}
