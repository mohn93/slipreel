import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/device_frame_catalog_provider.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Background tab — wallpaper picker, blur, padding, corners, inset.
///
/// All controls write through to [editorProjectControllerProvider]'s
/// `windowFrame` so the playback canvas re-renders live and the change
/// persists via the per-clip sidecar.
class BackgroundTab extends ConsumerStatefulWidget {
  const BackgroundTab({super.key, this.isDevice = false, this.recordingSize = Size.zero});

  final bool isDevice;
  final Size recordingSize;

  @override
  ConsumerState<BackgroundTab> createState() => _BackgroundTabState();
}

class _BackgroundTabState extends ConsumerState<BackgroundTab> {
  /// Local-only because the user can pick a category without
  /// committing to a tile yet. Initialized from the model so the
  /// chip selection persists across rebuilds. Lazily initialized on
  /// first build so we can seed from the current project state.
  String? _selectedCategory;

  /// Whether the device-frame picker shows flexible (all) vs perfect
  /// (exact-match only) device entries. Local-only UI state.
  bool _flexible = false;

  /// Apply a copyWith mutation to the project's current windowFrame and
  /// re-tag the result as 'Custom' — matches the legacy
  /// FrameSettingsProvider.updateXxx contract so the template chip
  /// flips off the moment any field is hand-tweaked.
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

  void _updatePadding(double padding) => _mutateFrame(
        (f) => f.copyWith(padding: EdgeInsets.all(padding), name: 'Custom'),
      );

  void _updateCornerRadius(double radius) => _mutateFrame(
        (f) => f.copyWith(cornerRadius: radius, name: 'Custom'),
      );

  void _updateBackgroundBlur(double sigma) => _mutateFrame(
        (f) => f.copyWith(backgroundBlur: sigma, name: 'Custom'),
      );

  void _updateInset(double inset) => _mutateFrame(
        (f) => f.copyWith(inset: inset, name: 'Custom'),
      );

  void _updateWallpaper({required String? category, int index = 0}) {
    _mutateFrame((f) {
      if (category == null) {
        return f.copyWith(clearWallpaper: true, name: 'Custom');
      }
      return f.copyWith(
        wallpaperCategory: category,
        wallpaperIndex: index,
        name: 'Custom',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final frame = ref.watch(editorProjectControllerProvider).windowFrame;
    // Seed/auto-sync the local category. Mirrors the previous
    // FrameSettingsProvider listener (which jumped the chip to the
    // chosen wallpaper's category when an external write — e.g. the
    // sidecar load — landed).
    _selectedCategory ??= frame.wallpaperCategory ?? 'macOS';
    final liveCategory = frame.wallpaperCategory;
    if (liveCategory != null && liveCategory != _selectedCategory) {
      _selectedCategory = liveCategory;
    }
    final selectedCategory = _selectedCategory!;

    final padding = frame.padding.left;
    final cornerRadius = frame.cornerRadius;
    final selectedIndex = frame.wallpaperCategory == selectedCategory
        ? frame.wallpaperIndex
        : -1;

    return ListView(
      padding: EdgeInsets.zero,
      // Let hover lean/tilt overshoot paint past the panel edge.
      clipBehavior: Clip.none,
      children: [
        if (widget.isDevice) ...[
          _deviceFrameSection(frame),
          const InspectorSectionDivider(),
        ],
        _wallpaperHeader(),
        const SizedBox(height: 12),
        InspectorChipGroup<String>(
          items: kWallpaperCategories,
          labelOf: (s) => s,
          iconOf: (s) => s == 'Favorite' ? Icons.star_border : null,
          selected: selectedCategory,
          onSelected: (s) => setState(() {
            _selectedCategory = s;
          }),
        ),
        const SizedBox(height: 16),
        _randomButton(selectedCategory),
        const SizedBox(height: 16),
        _wallpaperGrid(selectedCategory, selectedIndex),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Background blur',
          subtitle: frame.backgroundBlur > 0
              ? '${frame.backgroundBlur.toStringAsFixed(0)} px'
              : 'Off',
          value: frame.backgroundBlur,
          min: 0,
          max: 60,
          onChanged: _updateBackgroundBlur,
          onReset: () => _updateBackgroundBlur(0),
          canReset: frame.backgroundBlur != 0,
        ),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Padding',
          value: padding,
          min: 0,
          max: 200,
          onChanged: _updatePadding,
          onReset: () => _updatePadding(40),
          canReset: padding != 40,
        ),
        const SizedBox(height: 24),
        InspectorSlider(
          label: 'Rounded corners',
          value: cornerRadius,
          min: 0,
          max: 60,
          onChanged: _updateCornerRadius,
          onReset: () => _updateCornerRadius(12),
          canReset: cornerRadius != 12,
        ),
        const SizedBox(height: 24),
        InspectorSlider(
          label: 'Inset',
          subtitle: frame.inset > 0
              ? '${frame.inset.toStringAsFixed(0)} px'
              : 'Off',
          value: frame.inset,
          min: 0,
          max: 60,
          onChanged: _updateInset,
          onReset: () => _updateInset(0),
          canReset: frame.inset != 0,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _deviceFrameSection(WindowFrame frame) {
    final catalogAsync = ref.watch(deviceFrameCatalogProvider);
    return catalogAsync.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (catalog) {
        final enabled = frame.deviceFrameId != null;
        final entries = _flexible
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
              selected: _flexible,
              onSelected: (b) => setState(() => _flexible = b),
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
      },
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

  Widget _wallpaperHeader() {
    return const Text(
      'Wallpaper',
      style: TextStyle(
        color: kInspectorMuted,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _randomButton(String category) {
    return SpringHoverButton(
      onTap: () => _updateWallpaper(
        category: category,
        index: Random().nextInt(kWallpapersPerCategory),
      ),
      borderRadius: 12,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kInspectorBorder),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome,
                color: Colors.white, size: 16),
            SizedBox(width: 8),
            Text(
              'Pick random wallpaper',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wallpaperGrid(String category, int selectedIndex) {
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1,
      children: [
        for (int i = 0; i < kWallpapersPerCategory; i++)
          _WallpaperThumb(
            decoration: wallpaperDecoration(category, i),
            isSelected: i == selectedIndex,
            onTap: () => _updateWallpaper(
              category: category,
              index: i,
            ),
          ),
      ],
    );
  }
}

class _WallpaperThumb extends StatelessWidget {
  const _WallpaperThumb({
    required this.decoration,
    required this.isSelected,
    required this.onTap,
  });

  final BoxDecoration decoration;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      onTap: onTap,
      borderRadius: 8,
      child: Container(
        decoration: decoration.copyWith(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? kInspectorAccent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
    );
  }
}
