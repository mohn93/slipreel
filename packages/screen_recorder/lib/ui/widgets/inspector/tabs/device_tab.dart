import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/device_frame_catalog_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Whether the device-frame picker shows flexible (all compatible) vs perfect
/// (exact-match only) entries.
///
/// Session-scoped and deliberately NOT autoDispose: the inspector rebuilds
/// [DeviceTab] from scratch on every tab switch (see `inspector_panel.dart`'s
/// `switch`), so keeping this in widget State reset it to Perfect on every
/// revisit. A keep-alive provider survives the rebuild.
final deviceFramePickerFlexibleProvider = StateProvider<bool>((ref) => false);

/// Device tab — wraps an iPhone/iPad recording in a realistic device mockup.
///
/// Only shown in the inspector rail for device captures (see
/// [visibleInspectorTabs]). All controls write through to
/// [editorProjectControllerProvider]'s `windowFrame` so the playback canvas
/// re-renders live and the change persists via the per-clip sidecar.
class DeviceTab extends ConsumerStatefulWidget {
  const DeviceTab({super.key, this.recordingSize = Size.zero});

  /// The recording's source resolution — drives Perfect (exact) matching.
  final Size recordingSize;

  @override
  ConsumerState<DeviceTab> createState() => _DeviceTabState();
}

class _DeviceTabState extends ConsumerState<DeviceTab> {
  void _mutateFrame(WindowFrame Function(WindowFrame) update) {
    final notifier = ref.read(editorProjectControllerProvider.notifier);
    final current = notifier.current.windowFrame;
    final next = update(current);
    if (next == current) return;
    notifier.setWindowFrame(next);
  }

  void _setDeviceColor(String deviceId, String colorId) => _mutateFrame(
        (f) => f.copyWith(deviceFrameId: deviceId, deviceFrameColor: colorId),
      );

  void _disableDeviceFrame() =>
      _mutateFrame((f) => f.copyWith(clearDeviceFrame: true));

  void _setAdjustSize(bool v) =>
      _mutateFrame((f) => f.copyWith(deviceFrameAdjustSize: v));

  @override
  Widget build(BuildContext context) {
    final frame = ref.watch(editorProjectControllerProvider).windowFrame;
    final flexible = ref.watch(deviceFramePickerFlexibleProvider);
    final catalogAsync = ref.watch(deviceFrameCatalogProvider);
    return ListView(
      padding: EdgeInsets.zero,
      clipBehavior: Clip.none,
      children: [
        catalogAsync.maybeWhen(
          orElse: () => const SizedBox.shrink(),
          data: (catalog) => _deviceFrameSection(frame, catalog, flexible),
        ),
      ],
    );
  }

  Widget _deviceFrameSection(
      WindowFrame frame, DeviceFrameCatalog catalog, bool flexible) {
    final enabled = frame.deviceFrameId != null;
    final entries = flexible
        ? flexibleMatches(catalog, widget.recordingSize)
        : perfectMatches(catalog, widget.recordingSize);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const InspectorSectionLabel('Device frame'),
        const SizedBox(height: 8),
        InspectorToggle(
          label: 'Use device mockup',
          subtitle: 'Wrap the recording in a device mockup.',
          value: enabled,
          onChanged: (v) {
            if (!v) {
              _disableDeviceFrame();
            } else {
              // Turn on by selecting the first available match.
              final list = entries.isNotEmpty
                  ? entries
                  : flexibleMatches(catalog, widget.recordingSize);
              if (list.isNotEmpty && list.first.colors.isNotEmpty) {
                _setDeviceColor(list.first.id, list.first.colors.first.id);
              }
            }
          },
        ),
        const SizedBox(height: 12),
        if (enabled) ...[
          InspectorToggle(
            label: 'Adjust device size',
            subtitle: 'Stretch or shrink the mockup to match the recording.',
            value: frame.deviceFrameAdjustSize,
            onChanged: _setAdjustSize,
          ),
          const SizedBox(height: 12),
        ],
        InspectorChipGroup<bool>(
          items: const [false, true],
          labelOf: (b) => b ? 'Flexible' : 'Perfect',
          selected: flexible,
          onSelected: (b) =>
              ref.read(deviceFramePickerFlexibleProvider.notifier).state = b,
        ),
        const SizedBox(height: 12),
        for (final entry in entries) _deviceColorRow(frame, entry),
        if (entries.isEmpty)
          const Text(
            'No matching device frames.',
            style: TextStyle(color: kInspectorMuted, fontSize: 12),
          ),
      ],
    );
  }

  Widget _deviceColorRow(WindowFrame frame, DeviceFrameEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.family,
            style: const TextStyle(color: kInspectorMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in entry.colors)
                InspectorChip(
                  label: c.name,
                  selected: frame.deviceFrameId == entry.id &&
                      frame.deviceFrameColor == c.id,
                  onTap: () => _setDeviceColor(entry.id, c.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
