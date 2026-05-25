import 'package:flutter/material.dart';

import 'elapsed_format.dart';

/// The window collapses to this while recording: a pulsing red dot, the
/// elapsed time, and a stop button. Fills the window edge-to-edge — the native
/// window supplies the capsule rounding + drop shadow, so there is no second
/// border drawn here (which previously fought the window's rounded mask).
class RecordingPill extends StatelessWidget {
  const RecordingPill({super.key, required this.elapsed, required this.onStop});

  final Duration elapsed;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      color: const Color(0xFF2C2C30),
      padding: const EdgeInsets.symmetric(horizontal: 14),
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
          GestureDetector(
            key: const Key('pill-stop'),
            onTap: onStop,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: const Color(0xFFE5484D),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.stop_rounded, color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}
