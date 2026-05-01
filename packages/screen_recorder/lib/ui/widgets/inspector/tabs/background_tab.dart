import 'dart:math';

import 'package:flutter/material.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Background tab — wallpaper picker, blur, padding, corners, inset.
///
/// Padding and rounded corners write through to FrameSettingsProvider
/// (already wired into the playback render path). Wallpaper category /
/// thumbnail and inset are local-state-only for now: the model
/// doesn't carry a wallpaper concept yet, so the picker behaves
/// correctly visually but doesn't change the rendered frame.
class BackgroundTab extends StatefulWidget {
  const BackgroundTab({super.key, required this.frameSettings});
  final FrameSettingsProvider frameSettings;

  @override
  State<BackgroundTab> createState() => _BackgroundTabState();
}

class _BackgroundTabState extends State<BackgroundTab> {
  static const _categories = <String>[
    'Favorite',
    'macOS',
    'Spring',
    'Sunset',
    'Radial',
    'Solid',
  ];
  String _selectedCategory = 'macOS';
  int _selectedWallpaper = 0;
  double _backgroundBlur = 0;
  double _inset = 0;

  static const _wallpapersPerCategory = 16;

  @override
  Widget build(BuildContext context) {
    final frame = widget.frameSettings.currentFrame;
    final padding = frame.padding.left;
    final cornerRadius = frame.cornerRadius;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _wallpaperHeader(),
        const SizedBox(height: 12),
        InspectorChipGroup<String>(
          items: _categories,
          labelOf: (s) => s,
          iconOf: (s) => s == 'Favorite' ? Icons.star_border : null,
          selected: _selectedCategory,
          onSelected: (s) => setState(() {
            _selectedCategory = s;
            _selectedWallpaper = 0;
          }),
        ),
        const SizedBox(height: 16),
        _randomButton(),
        const SizedBox(height: 16),
        _wallpaperGrid(),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Background blur',
          value: _backgroundBlur,
          min: 0,
          max: 1,
          onChanged: (v) => setState(() => _backgroundBlur = v),
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
          value: _inset,
          min: 0,
          max: 100,
          onChanged: (v) => setState(() => _inset = v),
          onReset: () => setState(() => _inset = 0),
          canReset: _inset != 0,
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
      onTap: () => setState(() {
        _selectedWallpaper =
            Random().nextInt(_wallpapersPerCategory);
      }),
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

  Widget _wallpaperGrid() {
    // Synthetic gradient thumbnails until we have a real wallpaper
    // catalog. Each tile is a deterministic gradient seeded on the
    // (category, index) pair so swapping categories produces a
    // different-looking palette.
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1,
      children: [
        for (int i = 0; i < _wallpapersPerCategory; i++)
          _WallpaperThumb(
            seed: '$_selectedCategory.$i'.hashCode,
            isSelected: i == _selectedWallpaper,
            onTap: () =>
                setState(() => _selectedWallpaper = i),
          ),
      ],
    );
  }
}

class _WallpaperThumb extends StatelessWidget {
  const _WallpaperThumb({
    required this.seed,
    required this.isSelected,
    required this.onTap,
  });

  final int seed;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = Random(seed);
    final hue1 = r.nextDouble() * 360;
    final hue2 = (hue1 + 30 + r.nextDouble() * 90) % 360;
    final c1 =
        HSLColor.fromAHSL(1, hue1, 0.6, 0.55).toColor();
    final c2 =
        HSLColor.fromAHSL(1, hue2, 0.6, 0.4).toColor();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c1, c2],
          ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                isSelected ? kInspectorAccent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
    );
  }
}
