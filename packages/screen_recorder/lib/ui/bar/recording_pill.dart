import 'package:flutter/material.dart';

import 'elapsed_format.dart';

/// The window collapses to this while recording: a pulsing red dot, the
/// elapsed time, and a stop button. Pure presentation.
class RecordingPill extends StatelessWidget {
  const RecordingPill({super.key, required this.elapsed, required this.onStop});

  final Duration elapsed;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: const BoxDecoration(
              color: Color(0xFFE5484D),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatElapsed(elapsed),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            key: const Key('pill-stop'),
            tooltip: 'Stop recording',
            onPressed: onStop,
            icon: const Icon(Icons.stop_rounded),
            color: Colors.white,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFE5484D),
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}
