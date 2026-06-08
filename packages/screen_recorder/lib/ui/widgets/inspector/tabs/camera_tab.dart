import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Global camera look controls. Reads/writes `cameraSettings` on the editor
/// notifier. Shows a disabled placeholder when the recording has no camera
/// sidecar.
class CameraTab extends ConsumerWidget {
  const CameraTab({super.key, this.hasCamera = false});

  /// Whether this recording has a `.camera.mov` sidecar. When false the tab
  /// is informational only.
  final bool hasCamera;

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
