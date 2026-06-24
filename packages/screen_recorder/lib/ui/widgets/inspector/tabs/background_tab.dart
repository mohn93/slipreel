import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/wallpaper_favorites_controller.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/color_picker_field.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Decode width for the picker's photo thumbnails. The source wallpapers are
/// ~2400px wide (~15 MB decoded each); decoding 16 at full res to draw ~50px
/// tiles overruns Flutter's image cache and stutters. ~256px is generously
/// crisp for the tile (cover, up to 3× DPR) at a fraction of the memory.
const int _kWallpaperThumbCacheWidth = 256;

/// Background tab — wallpaper picker, blur, padding, corners, inset.
///
/// All controls write through to [editorProjectControllerProvider]'s
/// `windowFrame` so the playback canvas re-renders live and the change
/// persists via the per-clip sidecar.
class BackgroundTab extends ConsumerStatefulWidget {
  const BackgroundTab({super.key});

  @override
  ConsumerState<BackgroundTab> createState() => _BackgroundTabState();
}

class _BackgroundTabState extends ConsumerState<BackgroundTab> {
  /// Local-only because the user can pick a category without
  /// committing to a tile yet. Initialized from the model so the
  /// chip selection persists across rebuilds. Lazily initialized on
  /// first build so we can seed from the current project state.
  String? _selectedCategory;

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

  void _updateSolidColor(Color color) => _mutateFrame(
        (f) => f.copyWith(
          wallpaperCategory: 'Solid',
          solidColor: color,
          name: 'Custom',
        ),
      );

  @override
  Widget build(BuildContext context) {
    final frame = ref.watch(editorProjectControllerProvider).windowFrame;
    final favorites = ref.watch(wallpaperFavoritesProvider);
    // Seed/auto-sync the local category. Mirrors the previous
    // FrameSettingsProvider listener (which jumped the chip to the
    // chosen wallpaper's category when an external write — e.g. the
    // sidecar load — landed).
    _selectedCategory ??= frame.wallpaperCategory ?? 'macOS';
    final liveCategory = frame.wallpaperCategory;
    if (liveCategory != null &&
        liveCategory != _selectedCategory &&
        _selectedCategory != 'Favorite' &&
        _selectedCategory != 'Solid') {
      _selectedCategory = liveCategory;
    }
    final selectedCategory = _selectedCategory!;

    final padding = frame.padding.left;
    final cornerRadius = frame.cornerRadius;

    return ListView(
      padding: EdgeInsets.zero,
      // Let hover lean/tilt overshoot paint past the panel edge.
      clipBehavior: Clip.none,
      children: [
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
        _randomButton(selectedCategory, favorites),
        const SizedBox(height: 16),
        _gridRegion(selectedCategory, frame, favorites),
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

  Widget _randomButton(String category, List<WallpaperRef> favorites) {
    return SpringHoverButton(
      onTap: () {
        if (category == 'Favorite') {
          if (favorites.isEmpty) return; // nothing to pick from yet
          final pick = favorites[Random().nextInt(favorites.length)];
          _updateWallpaper(category: pick.category, index: pick.index);
        } else {
          _updateWallpaper(
            category: category,
            index: Random().nextInt(kWallpapersPerCategory),
          );
        }
      },
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

  Widget _gridRegion(
    String category,
    WindowFrame frame,
    List<WallpaperRef> favorites,
  ) {
    final Widget content;
    if (category == 'Solid') {
      final seed = frame.solidColor ??
          (frame.wallpaperCategory != null
              ? wallpaperRepresentativeColor(
                  frame.wallpaperCategory!, frame.wallpaperIndex)
              : const Color(0xFF5B6470));
      final notifier = ref.read(wallpaperFavoritesProvider.notifier);
      final isFav = frame.solidColor != null &&
          favorites.contains(WallpaperRef.color(frame.solidColor!));
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColorPickerField(color: seed, onChanged: _updateSolidColor),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('favorite-current-color'),
              onPressed: () => notifier.toggle(
                  WallpaperRef.color(frame.solidColor ?? seed)),
              icon: Icon(isFav ? Icons.star : Icons.star_border,
                  size: 16, color: Colors.white),
              label: Text(isFav ? 'Favorited' : 'Add to Favorites',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        ],
      );
    } else if (category == 'Favorite') {
      content = favorites.isEmpty
          ? _favoritesEmptyState()
          : _favoritesGrid(frame, favorites);
    } else {
      final selectedIndex =
          frame.wallpaperCategory == category ? frame.wallpaperIndex : -1;
      content = _wallpaperGrid(category, selectedIndex, favorites);
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: content,
    );
  }

  Widget _favoritesGrid(WindowFrame frame, List<WallpaperRef> favorites) {
    final notifier = ref.read(wallpaperFavoritesProvider.notifier);
    final WallpaperRef? current;
    if (frame.wallpaperCategory == 'Solid' && frame.solidColor != null) {
      current = WallpaperRef.color(frame.solidColor!);
    } else if (frame.wallpaperCategory != null) {
      current = WallpaperRef.photo(frame.wallpaperCategory!, frame.wallpaperIndex);
    } else {
      current = null;
    }
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1,
      children: [
        for (final wref in favorites)
          _WallpaperThumb(
            key: ValueKey(wref.encode()),
            decoration: wref.isColor
                ? BoxDecoration(color: wref.color)
                : wallpaperDecoration(wref.category, wref.index,
                    thumbCacheWidth: _kWallpaperThumbCacheWidth),
            isSelected: wref == current,
            isFavorite: true,
            onTap: () => wref.isColor
                ? _updateSolidColor(wref.color!)
                : _updateWallpaper(category: wref.category, index: wref.index),
            onToggleFavorite: () => notifier.toggle(wref),
          ),
      ],
    );
  }

  Widget _favoritesEmptyState() {
    return const InspectorPlaceholder(
      icon: Icons.star_border,
      title: 'No favorites yet',
      body: 'Right-click any wallpaper and choose Add to Favorites '
          'to save it here.',
    );
  }

  Widget _wallpaperGrid(
    String category,
    int selectedIndex,
    List<WallpaperRef> favorites,
  ) {
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
          _categoryThumb(category, i, selectedIndex, favorites),
      ],
    );
  }

  Widget _categoryThumb(
    String category,
    int i,
    int selectedIndex,
    List<WallpaperRef> favorites,
  ) {
    final wref = WallpaperRef.photo(category, i);
    return _WallpaperThumb(
      key: ValueKey(wref.encode()),
      decoration: wallpaperDecoration(category, i,
          thumbCacheWidth: _kWallpaperThumbCacheWidth),
      isSelected: i == selectedIndex,
      isFavorite: favorites.contains(wref),
      onTap: () => _updateWallpaper(category: category, index: i),
      onToggleFavorite: () =>
          ref.read(wallpaperFavoritesProvider.notifier).toggle(wref),
    );
  }
}

class _WallpaperThumb extends StatelessWidget {
  const _WallpaperThumb({
    super.key,
    required this.decoration,
    required this.isSelected,
    required this.isFavorite,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final BoxDecoration decoration;
  final bool isSelected;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  Future<void> _showFavoriteMenu(BuildContext context, Offset globalPos) async {
    final renderObject = Overlay.of(context).context.findRenderObject();
    if (renderObject is! RenderBox) return;
    final overlay = renderObject;
    final selected = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      color: kInspectorPanel,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: kInspectorBorder),
      ),
      items: [
        PopupMenuItem<bool>(
          value: true,
          height: 36,
          child: Row(
            children: [
              Icon(isFavorite ? Icons.star : Icons.star_border,
                  size: 16, color: Colors.white),
              const SizedBox(width: 10),
              Text(
                isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
    if (selected == true) onToggleFavorite();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (d) => _showFavoriteMenu(context, d.globalPosition),
      child: SpringHoverButton(
        onTap: onTap,
        borderRadius: 8,
        child: Stack(
          children: [
            Container(
              decoration: decoration.copyWith(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? kInspectorAccent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            if (isFavorite)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.star, size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
