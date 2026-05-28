import 'dart:math';
import 'package:flutter/painting.dart';

/// Categories shown in the inspector's wallpaper picker. The order
/// here matches the chip order so the picker UI doesn't need its own
/// list.
const List<String> kWallpaperCategories = [
  'Favorite',
  'macOS',
  'Spring',
  'Sunset',
  'Radial',
  'Solid',
];

/// How many tiles each category exposes in the picker grid.
const int kWallpapersPerCategory = 16;

/// Photo-backed categories: file names live under
/// `assets/wallpapers/<dir>/` and are declared in `pubspec.yaml`. The
/// order is stable and persisted in project JSON — don't reorder
/// without a migration. Unsplash-licensed (commercial use, no
/// attribution required).
const Map<String, List<String>> _photoCategoryFiles = {
  'macOS': [
    '01_pink_purple_wave.jpg',
    '02_purple_green_glow.jpg',
    '03_liquid_multicolor.jpg',
    '04_pastel_flow.jpg',
    '05_white_wavy_lines.jpg',
    '06_sky_gradient.jpg',
    '07_mountain_blue_fog.jpg',
    '08_layered_ridges.jpg',
    '09_neon_pink_sunset.jpg',
    '10_nevada_sunset.jpg',
    '11_snowy_peaks_sunset.jpg',
    '12_blue_sky_ocean.jpg',
    '13_grey_minimal_sea.jpg',
    '14_purple_orange_clouds.jpg',
    '15_aurora_green.jpg',
    '16_aurora_reflection.jpg',
  ],
  'Spring': [
    '01_cherry_backlit.jpg',
    '02_cherry_white_sky.jpg',
    '03_cherry_blue_sky.jpg',
    '04_cherry_pathway.jpg',
    '05_cherry_water.jpg',
    '06_green_hills.jpg',
    '07_grass_backlit.jpg',
    '08_hyacinth_fields.jpg',
    '09_pink_tulips.jpg',
    '10_pastel_sky.jpg',
    '11_rapeseed_pink_sky.jpg',
    '12_pastel_clouds.jpg',
    '13_cornflower_meadow.jpg',
    '14_poppy_meadow.jpg',
    '15_dewy_meadow.jpg',
    '16_dew_macro.jpg',
  ],
};

/// Map of [_photoCategoryFiles] keys to their on-disk directory name
/// under `assets/wallpapers/`. Keeps the user-visible category label
/// ("macOS") decoupled from the directory name ("macos").
const Map<String, String> _photoCategoryDirs = {
  'macOS': 'macos',
  'Spring': 'spring',
};

/// Whether [category] renders from bundled photos (vs. a procedural
/// gradient). Favorite is treated as macOS for now.
bool isPhotoWallpaperCategory(String category) {
  if (category == 'Favorite') return true;
  return _photoCategoryFiles.containsKey(category);
}

/// Asset path for a photo wallpaper at [category]/[index] (clamped to
/// range). Returns null when [category] is procedural. Exposed so the
/// export pipeline can preload the asset as a `ui.Image` rather than
/// going through the async `DecorationImage`/`BoxPainter` path.
String? photoWallpaperAsset(String category, int index) {
  // Historic alias — Favorite shares the macOS pool until a real
  // favoriting system lands.
  final key = category == 'Favorite' ? 'macOS' : category;
  final files = _photoCategoryFiles[key];
  final dir = _photoCategoryDirs[key];
  if (files == null || dir == null) return null;
  final clamped = index.clamp(0, files.length - 1);
  return 'assets/wallpapers/$dir/${files[clamped]}';
}

/// Returns a [BoxDecoration] that renders the wallpaper for
/// `(category, index)`. Used by both the picker tiles and the
/// playback canvas so they look identical.
///
/// "Favorite" shares the macOS palette today — there's no real
/// favoriting yet; this keeps the chip non-empty so users can preview
/// it.
BoxDecoration wallpaperDecoration(String category, int index) {
  final r = Random('$category.$index'.hashCode);
  if (isPhotoWallpaperCategory(category)) {
    return _photoDecoration(category, index);
  }
  switch (category) {
    case 'Sunset':
      return _sunsetGradient(r);
    case 'Radial':
      return _radialGradient(r);
    case 'Solid':
      return _solid(r);
    default:
      return _photoDecoration('macOS', index);
  }
}

BoxDecoration _photoDecoration(String category, int index) {
  final path = photoWallpaperAsset(category, index)!;
  return BoxDecoration(
    image: DecorationImage(
      image: AssetImage(path),
      fit: BoxFit.cover,
      // Higher filter quality for the picker tiles — when scaled down
      // to thumbnail size the default linear filter looks soft.
      filterQuality: FilterQuality.medium,
    ),
  );
}

BoxDecoration _sunsetGradient(Random r) {
  // Warm, orange→pink→purple sweep.
  final hue1 = 5 + r.nextDouble() * 35; // 5–40 (red→orange)
  final hue2 = 280 + r.nextDouble() * 40; // 280–320 (purple→magenta)
  final hueMid = 320 + r.nextDouble() * 30; // 320–350 (pink)
  final c1 = HSLColor.fromAHSL(1, hue1, 0.85, 0.55).toColor();
  final c2 = HSLColor.fromAHSL(1, hueMid, 0.70, 0.50).toColor();
  final c3 = HSLColor.fromAHSL(1, hue2, 0.55, 0.30).toColor();
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [c1, c2, c3],
      stops: const [0.0, 0.55, 1.0],
    ),
  );
}

BoxDecoration _radialGradient(Random r) {
  final hue1 = r.nextDouble() * 360;
  final hue2 = (hue1 + 140 + r.nextDouble() * 60) % 360;
  final c1 = HSLColor.fromAHSL(1, hue1, 0.65, 0.55).toColor();
  final c2 = HSLColor.fromAHSL(1, hue2, 0.55, 0.18).toColor();
  return BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(
        (r.nextDouble() - 0.5) * 1.2,
        (r.nextDouble() - 0.5) * 1.2,
      ),
      radius: 0.9 + r.nextDouble() * 0.4,
      colors: [c1, c2],
    ),
  );
}

BoxDecoration _solid(Random r) {
  // Deep, saturated single tone — looks intentional rather than dim.
  final hue = r.nextDouble() * 360;
  final color = HSLColor.fromAHSL(1, hue, 0.55, 0.32).toColor();
  return BoxDecoration(color: color);
}

/// Hand-tuned dominant-color approximations for each photo-backed
/// category, in the same order as [_photoCategoryFiles]. Used by
/// [wallpaperRepresentativeColor] (the inspector ring's tint derives
/// from this). Eye-balled from the photos themselves — not perfect,
/// but better than the neutral-grey fallback.
const Map<String, List<Color>> _photoCategoryColors = {
  'macOS': [
    Color(0xFFE7C9DA), // 01 pink_purple_wave
    Color(0xFF6B5BBF), // 02 purple_green_glow
    Color(0xFFD487A1), // 03 liquid_multicolor
    Color(0xFFB7CADC), // 04 pastel_flow
    Color(0xFFB8B8C8), // 05 white_wavy_lines
    Color(0xFFE69C77), // 06 sky_gradient
    Color(0xFF8BA1B5), // 07 mountain_blue_fog
    Color(0xFF5B7286), // 08 layered_ridges
    Color(0xFFE85A7E), // 09 neon_pink_sunset
    Color(0xFFE07845), // 10 nevada_sunset
    Color(0xFFD46B68), // 11 snowy_peaks_sunset
    Color(0xFF5DA0CC), // 12 blue_sky_ocean
    Color(0xFF8A93A0), // 13 grey_minimal_sea
    Color(0xFF8C5A8F), // 14 purple_orange_clouds
    Color(0xFF1F5D43), // 15 aurora_green
    Color(0xFF2E5F7E), // 16 aurora_reflection
  ],
  'Spring': [
    Color(0xFFE9B0BD), // 01 cherry_backlit
    Color(0xFFE5C2CC), // 02 cherry_white_sky
    Color(0xFFC97D9A), // 03 cherry_blue_sky
    Color(0xFFB6A2A6), // 04 cherry_pathway
    Color(0xFFE6A6B5), // 05 cherry_water
    Color(0xFF7FAE6C), // 06 green_hills
    Color(0xFFA8C56C), // 07 grass_backlit
    Color(0xFFD7A8C0), // 08 hyacinth_fields
    Color(0xFFE39FB5), // 09 pink_tulips
    Color(0xFFE7BCD3), // 10 pastel_sky
    Color(0xFFD9A28A), // 11 rapeseed_pink_sky
    Color(0xFFD2BBD0), // 12 pastel_clouds
    Color(0xFF6FA3C9), // 13 cornflower_meadow
    Color(0xFFC85E61), // 14 poppy_meadow
    Color(0xFF6A8D5C), // 15 dewy_meadow
    Color(0xFF89AE76), // 16 dew_macro
  ],
};

/// A single representative color for a wallpaper, used by the inset
/// ring's color derivation. For gradient wallpapers we return the
/// first stop (visually the "top" color); for photo-backed categories
/// we use a hand-tuned palette; for solids the color itself. Falls
/// back to neutral grey if the decoration shape is unknown.
Color wallpaperRepresentativeColor(String category, int index) {
  if (isPhotoWallpaperCategory(category)) {
    final key = category == 'Favorite' ? 'macOS' : category;
    final palette = _photoCategoryColors[key];
    if (palette != null && palette.isNotEmpty) {
      return palette[index.clamp(0, palette.length - 1)];
    }
  }
  final dec = wallpaperDecoration(category, index);
  final gradient = dec.gradient;
  if (gradient is LinearGradient && gradient.colors.isNotEmpty) {
    return gradient.colors.first;
  }
  if (gradient is RadialGradient && gradient.colors.isNotEmpty) {
    return gradient.colors.first;
  }
  if (dec.color != null) return dec.color!;
  return const Color(0xFF606070);
}
