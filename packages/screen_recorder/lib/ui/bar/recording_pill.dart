import 'package:flutter/material.dart';

import '../../state/recording_state.dart';
import 'elapsed_format.dart';

/// The window collapses to this while recording: status, elapsed time,
/// pause/resume, and a clearly labelled Finish action. Fills the window
/// edge-to-edge — native chrome supplies rounding and shadow.
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
    final isProcessing = status == RecordingStatus.processing;
    return Container(
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      color: const Color(0xFF2C2C30),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: isProcessing
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Color(0xFFB4B4BC),
                  ),
                ),
                SizedBox(width: 9),
                Text(
                  'Finishing recording…',
                  style: TextStyle(
                    color: Color(0xFFE9E9EC),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          : _LiveControls(
              isPaused: isPaused,
              elapsed: elapsed,
              onStop: onStop,
              onPauseOrResume: onPauseOrResume,
            ),
    );
  }
}

class _LiveControls extends StatelessWidget {
  const _LiveControls({
    required this.isPaused,
    required this.elapsed,
    required this.onStop,
    required this.onPauseOrResume,
  });

  final bool isPaused;
  final Duration elapsed;
  final VoidCallback onStop;
  final VoidCallback onPauseOrResume;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: isPaused ? const Color(0xFFF2B84B) : const Color(0xFFE5484D),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:
                    (isPaused
                            ? const Color(0xFFF2B84B)
                            : const Color(0xFFE5484D))
                        .withValues(alpha: 0.18),
                blurRadius: 5,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
        const SizedBox(width: 7),
        if (isPaused) ...[
          const Text(
            'Paused',
            style: TextStyle(
              color: Color(0xFFFFCF70),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 42),
          child: Text(
            formatElapsed(elapsed),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 9),
        _PillButton(
          key: Key(isPaused ? 'pill-resume' : 'pill-pause'),
          onTap: onPauseOrResume,
          color: isPaused ? const Color(0xFFF2B84B) : const Color(0xFF3F3F46),
          foregroundColor: isPaused ? const Color(0xFF25252A) : Colors.white,
          icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          semanticsLabel: isPaused ? 'Resume recording' : 'Pause recording',
        ),
        const SizedBox(width: 4),
        _PillButton(
          key: const Key('pill-stop'),
          onTap: onStop,
          color: const Color(0xFFE5484D),
          foregroundColor: Colors.white,
          icon: Icons.stop_rounded,
          label: 'Finish',
          width: 78,
          semanticsLabel: 'Finish recording',
        ),
      ],
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    super.key,
    required this.onTap,
    required this.color,
    required this.foregroundColor,
    required this.icon,
    required this.semanticsLabel,
    this.label,
    this.width = 38,
  });

  final VoidCallback onTap;
  final Color color;
  final Color foregroundColor;
  final IconData icon;
  final String semanticsLabel;
  final String? label;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: width,
          height: 38,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: foregroundColor, size: 18),
                  if (label != null) ...[
                    const SizedBox(width: 5),
                    Text(
                      label!,
                      style: TextStyle(
                        color: foregroundColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
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
