import 'dart:math';

import 'package:flutter/material.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Background tab — wallpaper picker, blur, padding, corners, inset.
///
/// All controls write through to [FrameSettingsProvider] so the
/// playback canvas re-renders live and the change persists via the
/// per-clip sidecar.
class BackgroundTab extends StatefulWidget {
  const BackgroundTab({super.key, required this.frameSettings});
  final FrameSettingsProvider frameSettings;

  @override
  State<BackgroundTab> createState() => _BackgroundTabState();
}

class _BackgroundTabState extends State<BackgroundTab> {
  /// Local-only because the user can pick a category without
  /// committing to a tile yet. Initialized from the model so the
  /// chip selection persists across rebuilds.
  late String _selectedCategory =
      widget.frameSettings.currentFrame.wallpaperCategory ?? 'macOS';

  @override
  void initState() {
    super.initState();
    widget.frameSettings.addListener(_onFrameChanged);
  }

  @override
  void dispose() {
    widget.frameSettings.removeListener(_onFrameChanged);
    super.dispose();
  }

  void _onFrameChanged() {
    final next = widget.frameSettings.currentFrame.wallpaperCategory;
    if (next != null && next != _selectedCategory) {
      setState(() => _selectedCategory = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frameSettings.currentFrame;
    final padding = frame.padding.left;
    final cornerRadius = frame.cornerRadius;
    final selectedIndex = frame.wallpaperCategory == _selectedCategory
        ? frame.wallpaperIndex
        : -1;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _wallpaperHeader(),
        const SizedBox(height: 12),
        InspectorChipGroup<String>(
          items: kWallpaperCategories,
          labelOf: (s) => s,
          iconOf: (s) => s == 'Favorite' ? Icons.star_border : null,
          selected: _selectedCategory,
          onSelected: (s) => setState(() {
            _selectedCategory = s;
          }),
        ),
        const SizedBox(height: 16),
        _randomButton(),
        const SizedBox(height: 16),
        _wallpaperGrid(selectedIndex),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Background blur',
          subtitle: frame.backgroundBlur > 0
              ? '${frame.backgroundBlur.toStringAsFixed(0)} px'
              : 'Off',
          value: frame.backgroundBlur,
          min: 0,
          max: 60,
          onChanged: widget.frameSettings.updateBackgroundBlur,
          onReset: () => widget.frameSettings.updateBackgroundBlur(0),
          canReset: frame.backgroundBlur != 0,
        ),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Padding',
          value: padding,
          min: 0,
          max: 200,
          onChanged: (v) => widget.frameSettings.updatePadding(v),
          onReset: () => widget.frameSettings.updatePadding(40),
          canReset: padding != 40,
        ),
        const SizedBox(height: 24),
        InspectorSlider(
          label: 'Rounded corners',
          value: cornerRadius,
          min: 0,
          max: 60,
          onChanged: (v) => widget.frameSettings.updateCornerRadius(v),
          onReset: () => widget.frameSettings.updateCornerRadius(12),
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
          onChanged: widget.frameSettings.updateInset,
          onReset: () => widget.frameSettings.updateInset(0),
          canReset: frame.inset != 0,
        ),
        const SizedBox(height: 24),
      ],
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

  Widget _randomButton() {
    return InkWell(
      onTap: () => widget.frameSettings.updateWallpaper(
        category: _selectedCategory,
        index: Random().nextInt(kWallpapersPerCategory),
      ),
      borderRadius: BorderRadius.circular(12),
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

  Widget _wallpaperGrid(int selectedIndex) {
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
            decoration: wallpaperDecoration(_selectedCategory, i),
            isSelected: i == selectedIndex,
            onTap: () => widget.frameSettings.updateWallpaper(
              category: _selectedCategory,
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
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
