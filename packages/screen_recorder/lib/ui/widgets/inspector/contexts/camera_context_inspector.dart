import 'package:flutter/material.dart';

import 'package:slipreel_engine/models/camera_region.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

/// Properties view shown when a camera region (pill) is selected. Look
/// controls (shape/roundness/mirror/border/shadow/opacity) live in the
/// global Camera tab; this context edits the per-region geometry (size) and
/// hosts delete. Position is edited by dragging the bubble on the canvas.
class CameraContextInspector extends StatelessWidget {
  const CameraContextInspector({
    super.key,
    required this.region,
    required this.regionNumber,
    required this.onChanged,
    required this.onDelete,
    required this.onClose,
  });

  final CameraRegion region;
  final int regionNumber;
  final ValueChanged<CameraRegion> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Camera $regionNumber',
          subtitle: _rangeLabel(region),
          onClose: onClose,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(right: 12),
            children: [
              const Text(
                'Drag the bubble on the preview to reposition it. Resize with '
                'the corner handles, or use the slider below.',
                style: TextStyle(color: kInspectorMuted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              InspectorSlider(
                label: 'Size',
                subtitle: '${(region.size * 100).round()}% of canvas width',
                value: region.size,
                min: 0.05,
                max: 1.0,
                onChanged: (v) => onChanged(region.copyWith(size: v)),
                onReset: () => onChanged(region.copyWith(size: 0.22)),
                canReset: (region.size - 0.22).abs() > 1e-6,
              ),
              const InspectorSectionDivider(),
              _DeleteButton(onPressed: onDelete),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  static String _rangeLabel(CameraRegion r) {
    String fmt(Duration d) {
      final m = d.inMinutes;
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }
    return '${fmt(r.startTime)} -> ${fmt(r.endTime)}';
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: kInspectorAccent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.account_box_outlined,
              color: kInspectorAccent, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(
                      color: kInspectorMuted, fontSize: 12)),
            ],
          ),
        ),
        SpringyIconButton(
          key: const Key('camera-region-close'),
          icon: Icons.close,
          tooltip: 'Close camera inspector',
          isActive: false,
          onTap: onClose,
          size: 32,
          iconSize: 16,
          tooltipPlacement: SpringyTooltipPlacement.bottom,
        ),
      ],
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      onTap: onPressed,
      borderRadius: 10,
      child: Container(
        key: const Key('camera-region-delete'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF3A1F26),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF8B2E3F)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete_outline, color: Color(0xFFE57373), size: 18),
            SizedBox(width: 8),
            Text('Delete camera region',
                style: TextStyle(
                    color: Color(0xFFE57373),
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
