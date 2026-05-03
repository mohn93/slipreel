import 'package:flutter/material.dart';

/// Skip-back / skip-forward button used in the transport bar above the
/// timeline. Shows a soft hover background and a rich tooltip that
/// includes the keyboard shortcut (e.g. "Go to last frame  ⌘ →").
class TransportButton extends StatefulWidget {
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
  State<TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<TransportButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      richMessage: TextSpan(
        children: [
          TextSpan(
            text: widget.tooltip,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const TextSpan(text: '   '),
          TextSpan(
            text: widget.shortcut,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A26),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF35354A)),
      ),
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      verticalOffset: 22,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _hovered
                  ? const Color(0xFF2B2B3D)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(widget.icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Circular outlined play/pause button shown between the skip
/// buttons in the transport bar.
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
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      verticalOffset: 26,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
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
      ),
    );
  }
}
