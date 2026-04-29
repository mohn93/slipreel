import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class RegionTabContent extends StatelessWidget {
  const RegionTabContent({
    super.key,
    required this.selection,
    required this.displayName,
    required this.onDraw,
    required this.isDrawing,
  });

  final RegionSelection? selection;
  final String? displayName;
  final VoidCallback onDraw;
  final bool isDrawing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selection == null)
              _buildEmpty(context)
            else
              _buildRecap(context),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.crop, size: 56, color: Colors.white38),
        const SizedBox(height: 16),
        const Text(
          'Draw a region of your screen',
          style: TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Click and drag anywhere on your desktop to capture a sub-region.',
          style: TextStyle(color: Colors.white60, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: isDrawing ? null : onDraw,
          icon: isDrawing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.crop),
          label: const Text('Draw a region'),
        ),
      ],
    );
  }

  Widget _buildRecap(BuildContext context) {
    final s = selection!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF6C63FF), width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${s.widthPx} × ${s.heightPx}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'on ${displayName ?? 'Display ${s.displayId}'}',
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: isDrawing ? null : onDraw,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Redraw'),
        ),
      ],
    );
  }
}
