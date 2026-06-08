import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/editor/camera_snap.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Global camera look controls. Reads/writes `cameraSettings` on the editor
/// notifier. Shows a disabled placeholder when the recording has no camera
/// sidecar.
class CameraTab extends ConsumerWidget {
  const CameraTab({
    super.key,
    this.hasCamera = false,
    this.canvasAspect = 16 / 9,
    this.originalAspect = 1.0,
  });

  /// Whether this recording has a `.camera.mov` sidecar. When false the tab
  /// is informational only.
  final bool hasCamera;

  /// Output-canvas aspect (w/h) and camera source aspect, used to keep the
  /// Position grid's anchors fully in view.
  final double canvasAspect;
  final double originalAspect;

  static const _shapes = <(CameraShape, String)>[
    (CameraShape.circle, 'Circle'),
    (CameraShape.square, 'Square'),
    (CameraShape.horizontal, 'Horizontal'),
    (CameraShape.vertical, 'Vertical'),
    (CameraShape.original, 'Original'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hasCamera) {
      return const InspectorPlaceholder(
        icon: Icons.account_box_outlined,
        title: 'No camera in this recording',
        body: 'Turn on the camera chip in the recording bar before you '
            'record to capture a webcam track. It will appear here as a '
            'picture-in-picture bubble you can place and style.',
      );
    }

    final settings = ref.watch(
      editorProjectControllerProvider.select((s) => s.cameraSettings),
    );
    final controller = ref.read(editorProjectControllerProvider.notifier);
    void update(CameraSettings next) => controller.setCameraSettings(next);

    final regions = ref.watch(
      editorProjectControllerProvider.select((s) => s.cameraRegions),
    );
    final current = regions.isEmpty
        ? null
        : Offset(regions.first.centerX, regions.first.centerY);
    // Edge-aware anchor centers (so a click never pushes the bubble off-canvas).
    final ext = cameraHalfExtents(
      size: regions.isEmpty ? 0.22 : regions.first.size,
      shapeAspect: settings.shape.pixelAspect(originalAspect),
      canvasAspect: canvasAspect,
    );
    final anchors = cameraSnapAnchors(halfW: ext.halfW, halfH: ext.halfH);

    return ListView(
      padding: const EdgeInsets.only(right: 12),
      children: [
        InspectorToggle(
          key: const Key('camera-enable-toggle'),
          label: 'Show camera',
          subtitle: 'Composite the webcam bubble in the preview and export.',
          value: settings.enabled,
          onChanged: (v) => update(settings.copyWith(enabled: v)),
        ),
        const InspectorSectionDivider(),
        const InspectorSectionLabel('Position'),
        const Text(
          'Click a spot to place the camera. Drag it on the preview (or hold '
          '⌥ Option) for free placement.',
          style: TextStyle(color: kInspectorMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _PositionGrid(
          anchors: anchors,
          current: current,
          onPick: regions.isEmpty
              ? null
              : (cx, cy) => controller.updateCameraRegionAt(
                    0,
                    regions.first.copyWith(centerX: cx, centerY: cy),
                  ),
        ),
        const InspectorSectionDivider(),
        const InspectorSectionLabel('Shape'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (shape, label) in _shapes)
              InspectorChip(
                label: label,
                selected: settings.shape == shape,
                onTap: () => update(settings.copyWith(shape: shape)),
                dense: true,
              ),
          ],
        ),
        const SizedBox(height: 20),
        // Roundness greys out for Circle (always fully round).
        Opacity(
          opacity: settings.shape.isRound ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: settings.shape.isRound,
            child: InspectorSlider(
              label: 'Roundness',
              subtitle: settings.shape.isRound
                  ? 'Circle is always fully round.'
                  : '${(settings.roundness * 100).round()}% corner radius',
              value: settings.roundness,
              min: 0,
              max: 1,
              onChanged: (v) => update(settings.copyWith(roundness: v)),
              onReset: () => update(settings.copyWith(roundness: 1.0)),
              canReset: settings.roundness != 1.0,
            ),
          ),
        ),
        const InspectorSectionDivider(),
        InspectorToggle(
          key: const Key('camera-mirror-toggle'),
          label: 'Mirror',
          subtitle: 'Flip horizontally (most webcams read more natural '
              'mirrored).',
          value: settings.mirror,
          onChanged: (v) => update(settings.copyWith(mirror: v)),
        ),
        const SizedBox(height: 16),
        InspectorToggle(
          label: 'Shadow',
          subtitle: 'Soft drop shadow under the bubble.',
          value: settings.shadow,
          onChanged: (v) => update(settings.copyWith(shadow: v)),
        ),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Border width',
          subtitle: settings.borderWidth <= 0
              ? 'No border'
              : '${settings.borderWidth.round()} px',
          value: settings.borderWidth,
          min: 0,
          max: 16,
          onChanged: (v) => update(settings.copyWith(borderWidth: v)),
          onReset: () => update(settings.copyWith(borderWidth: 0)),
          canReset: settings.borderWidth != 0,
        ),
        const SizedBox(height: 16),
        _BorderColorRow(
          selected: settings.borderColor,
          onPick: (c) => update(settings.copyWith(borderColor: c)),
        ),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Opacity',
          subtitle: '${(settings.opacity * 100).round()}%',
          value: settings.opacity,
          min: 0.2,
          max: 1,
          onChanged: (v) => update(settings.copyWith(opacity: v)),
          onReset: () => update(settings.copyWith(opacity: 1.0)),
          canReset: settings.opacity != 1.0,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _BorderColorRow extends StatelessWidget {
  const _BorderColorRow({required this.selected, required this.onPick});
  final int selected;
  final ValueChanged<int> onPick;

  static const _swatches = <int>[
    0xFFFFFFFF, 0xFF000000, 0xFF6C63FF, 0xFFE53935, 0xFF43A047, 0xFFFB8C00,
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Border color',
            style: TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in _swatches)
              GestureDetector(
                onTap: () => onPick(c),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == selected
                          ? const Color(0xFF6C63FF)
                          : const Color(0xFF35354A),
                      width: c == selected ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A 3×3 grid of the 9 standard PiP anchors. Clicking a cell places the camera
/// at that spot (same anchors the on-canvas drag snaps to). [current] (the
/// camera's normalized center) highlights the matching cell. Disabled when
/// [onPick] is null (no camera region yet).
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
  final void Function(double cx, double cy)? onPick;

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
        onTap: onPick == null ? null : () => onPick!(a.dx, a.dy),
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

    return Opacity(
      opacity: onPick == null ? 0.4 : 1.0,
      child: Column(
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
      ),
    );
  }
}
