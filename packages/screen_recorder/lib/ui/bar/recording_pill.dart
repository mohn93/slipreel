import 'package:flutter/material.dart';

import '../../state/recording_state.dart';
import 'elapsed_format.dart';

/// The window collapses to this while recording: a red dot (grey when paused),
/// the elapsed time, a pause/resume button, and a stop button. Fills the window
/// edge-to-edge — the native window supplies the capsule rounding + drop shadow,
/// so there is no second border drawn here.
class RecordingPill extends StatelessWidget {
  const RecordingPill({
    super.key,
    required this.status,
    required this.elapsed,
    required this.onStop,
    required this.onPauseOrResume,
  });

  final RecordingStatus status;
  final Duration elapsed;
  final VoidCallback onStop;
  final VoidCallback onPauseOrResume;

  @override
  Widget build(BuildContext context) {
    final isPaused = status == RecordingStatus.paused;
    // Native pill window is 156×48; the content (dot + "m:ss" text +
    // two 30px buttons + gaps) already runs ~137px, leaving ~19px for
    // padding. With a 14px symmetric padding the row overflowed (yellow
    // stripe) as soon as the timer crossed 9:59. Padding is squeezed to
    // 6px and the inter-element gaps trimmed so the row still fits when
    // the timer reaches three-digit minutes ("120:34") without growing
    // the window.
    return Container(
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      color: const Color(0xFF2C2C30),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: isPaused ? const Color(0xFF7E7E86) : const Color(0xFFE5484D),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatElapsed(elapsed),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          _PillButton(
            key: Key(isPaused ? 'pill-resume' : 'pill-pause'),
            onTap: onPauseOrResume,
            color: const Color(0xFF3F3F46),
            icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          ),
          const SizedBox(width: 4),
          _PillButton(
            key: const Key('pill-stop'),
            onTap: onStop,
            color: const Color(0xFFE5484D),
            icon: Icons.stop_rounded,
          ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({super.key, required this.onTap, required this.color, required this.icon});
  final VoidCallback onTap;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}
