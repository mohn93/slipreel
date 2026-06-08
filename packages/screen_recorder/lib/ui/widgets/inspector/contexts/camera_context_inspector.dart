import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/editor/camera_snap.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

/// Properties view shown when a camera region (pill) is selected. Look controls
/// (shape/roundness/mirror/border/shadow/opacity) are global and live in the
/// Camera tab; GEOMETRY is per-region and lives here: a position grid (the same
/// 9 anchors the on-canvas drag snaps to), a size slider, and delete. Each
/// camera segment owns its own placement, so positioning is always scoped to
/// the selected region — never one value shared across segments.
class CameraContextInspector extends ConsumerWidget {
  const CameraContextInspector({
    super.key,
    required this.region,
    required this.regionNumber,
    required this.onChanged,
    required this.onDelete,
    required this.onClose,
    this.canvasAspect = 16 / 9,
    this.originalAspect = 1.0,
  });

  final CameraRegion region;
  final int regionNumber;
  final ValueChanged<CameraRegion> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  /// Output-canvas aspect (w/h) and camera source aspect — used with the global
  /// shape to keep the position grid's anchors fully in view.
  final double canvasAspect;
  final double originalAspect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The bubble's rendered aspect (hence its in-view anchor insets) depends on
    // the global shape, so watch it and recompute when it changes.
    final shape = ref.watch(
      editorProjectControllerProvider.select((s) => s.cameraSettings.shape),
    );
    final ext = cameraHalfExtents(
      size: region.size,
      shapeAspect: shape.pixelAspect(originalAspect),
      canvasAspect: canvasAspect,
    );
    final anchors = cameraSnapAnchors(halfW: ext.halfW, halfH: ext.halfH);
    final current = Offset(region.centerX, region.centerY);

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
              const InspectorSectionLabel('Position'),
              const Text(
                "Click a spot to place this segment's camera, or drag the "
                'bubble on the preview (hold ⌥ Option for free placement). '
                'Resize with the corner handles or the slider below.',
                style: TextStyle(color: kInspectorMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              _PositionGrid(
                anchors: anchors,
                current: current,
                onPick: (cx, cy) =>
                    onChanged(region.copyWith(centerX: cx, centerY: cy)),
              ),
              const InspectorSectionDivider(),
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

/// A 3×3 grid of the 9 standard PiP anchors. Clicking a cell places the selected
/// region's camera at that spot (same anchors the on-canvas drag snaps to).
/// [current] (the region's normalized center) highlights the matching cell.
class _PositionGrid extends StatelessWidget {
  const _PositionGrid({
    required this.anchors,
    required this.current,
    required this.onPick,
  });

  /// The 9 edge-aware anchor CENTERS, row-major (top→bottom, left→right). Cell
  /// `row*3+col` places the camera at `anchors[row*3+col]`.
  final List<Offset> anchors;
  final Offset? current;
  final void Function(double cx, double cy) onPick;

  bool _isCurrent(Offset a) {
    final c = current;
    return c != null &&
        (c.dx - a.dx).abs() < 0.02 &&
        (c.dy - a.dy).abs() < 0.02;
  }

  @override
  Widget build(BuildContext context) {
    const cell = 46.0;
    Widget buildCell(int col, int row) {
      final a = anchors[row * 3 + col];
      final active = _isCurrent(a);
      return GestureDetector(
        key: Key('camera-pos-$row-$col'),
        onTap: () => onPick(a.dx, a.dy),
        child: Container(
          width: cell,
          height: cell,
          decoration: BoxDecoration(
            color: active
                ? kInspectorAccent.withValues(alpha: 0.15)
                : kInspectorPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? kInspectorAccent : kInspectorBorder,
              width: active ? 2 : 1,
            ),
          ),
          // A dot at the cell's SLOT (corner/edge/center) so the grid reads as
          // a position picker, independent of the inset anchor value.
          child: Align(
            alignment: Alignment((col - 1).toDouble(), (row - 1).toDouble()),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: active ? kInspectorAccent : const Color(0xFF6E6E80),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < 3; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (var col = 0; col < 3; col++) ...[
                  buildCell(col, row),
                  if (col < 2) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
