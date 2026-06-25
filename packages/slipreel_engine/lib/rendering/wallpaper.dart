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
  'Abstract',
  'Solid',
];

/// How many tiles each category exposes in the picker grid.
const int kWallpapersPerCategory = 16;

/// Legacy category renames. Projects and favorites persisted before a
/// category was renamed still carry the old string; [canonicalWallpaperCategory]
/// rewrites it on the way in so old data renders the replacement. 'Radial'
/// (a procedural gradient) became the photo-backed 'Abstract' set.
const Map<String, String> _legacyCategoryAliases = {
  'Radial': 'Abstract',
};

/// Canonicalizes a (possibly legacy) wallpaper category string. Pass any
/// persisted/decoded category through this before using it so renamed
/// categories keep resolving. Unknown strings pass through unchanged.
String canonicalWallpaperCategory(String category) =>
    _legacyCategoryAliases[category] ?? category;

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
  'Sunset': [
    '01_golden_sun_clouds.jpg',
    '02_golden_cloudscape.jpg',
    '03_sunrays_clouds.jpg',
    '04_golden_hour_sea.jpg',
    '05_orange_blue_sea.jpg',
    '06_orange_cloud_silhouette.jpg',
    '07_red_sun_horizon.jpg',
    '08_calm_golden_sea.jpg',
    '09_dramatic_horizon.jpg',
    '10_golden_sea_pastel.jpg',
    '11_pink_purple_sea.jpg',
    '12_violet_pink_sky.jpg',
    '13_pink_blue_clouds.jpg',
    '14_violet_ocean.jpg',
    '15_teal_seashore.jpg',
    '16_twilight_clouds.jpg',
  ],
  'Abstract': [
    '01_purple_glow.jpg',
    '02_lavender_haze.jpg',
    '03_blue_pink_mist.jpg',
    '04_indigo_folds.jpg',
    '05_indigo_waves.jpg',
    '06_teal_marble.jpg',
    '07_magenta_gradient.jpg',
    '08_spectrum_gradient.jpg',
    '09_warm_gradient.jpg',
    '10_ember_glow.jpg',
    '11_ribbon_waves.jpg',
    '12_flame_waves.jpg',
    '13_glossy_rings.jpg',
    '14_chrome_swirl.jpg',
    '15_violet_swirl.jpg',
    '16_teal_orange_burst.jpg',
  ],
};

/// Map of [_photoCategoryFiles] keys to their on-disk directory name
/// under `assets/wallpapers/`. Keeps the user-visible category label
/// ("macOS") decoupled from the directory name ("macos").
const Map<String, String> _photoCategoryDirs = {
  'macOS': 'macos',
  'Spring': 'spring',
  'Sunset': 'sunset',
  'Abstract': 'abstract',
};

/// Whether [category] renders from bundled photos (vs. the procedural
/// Solid fill). Favorite is treated as macOS for now.
bool isPhotoWallpaperCategory(String category) {
  final c = canonicalWallpaperCategory(category);
  if (c == 'Favorite') return true;
  return _photoCategoryFiles.containsKey(c);
}

/// Asset path for a photo wallpaper at [category]/[index] (clamped to
/// range). Returns null when [category] is procedural. Exposed so the
/// export pipeline can preload the asset as a `ui.Image` rather than
/// going through the async `DecorationImage`/`BoxPainter` path.
String? photoWallpaperAsset(String category, int index) {
  // Historic alias — Favorite shares the macOS pool until a real
  // favoriting system lands. Renamed categories (e.g. Radial→Abstract)
  // resolve through the canonical key.
  final canonical = canonicalWallpaperCategory(category);
  final key = canonical == 'Favorite' ? 'macOS' : canonical;
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
/// [thumbCacheWidth], when set (only the picker grid passes it), decodes
/// photo wallpapers at that pixel width via [ResizeImage] instead of full
/// resolution. The source JPEGs are ~2400px wide (~15 MB decoded each); a
/// grid of 16 full-res decodes blows past Flutter's 100 MB image cache and
/// stutters. The playback canvas/export pass no width and keep full res.
BoxDecoration wallpaperDecoration(
  String category,
  int index, {
  int? thumbCacheWidth,
  Color? solidColor,
}) {
  final canonical = canonicalWallpaperCategory(category);
  if (canonical == 'Solid' && solidColor != null) {
    return BoxDecoration(color: solidColor);
  }
  if (isPhotoWallpaperCategory(canonical)) {
    return _photoDecoration(canonical, index, thumbCacheWidth);
  }
  // Only legacy procedural solids remain (Solid with no custom color);
  // anything else falls back to the default macOS photo set.
  if (canonical == 'Solid') {
    return _solid(Random('$canonical.$index'.hashCode));
  }
  return _photoDecoration('macOS', index, thumbCacheWidth);
}

BoxDecoration _photoDecoration(String category, int index,
    [int? thumbCacheWidth]) {
  final path = photoWallpaperAsset(category, index)!;
  final AssetImage asset = AssetImage(path);
  return BoxDecoration(
    image: DecorationImage(
      image: thumbCacheWidth == null
          ? asset
          : ResizeImage(asset, width: thumbCacheWidth),
      fit: BoxFit.cover,
      // Higher filter quality for the picker tiles — when scaled down
      // to thumbnail size the default linear filter looks soft.
      filterQuality: FilterQuality.medium,
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
  // Sunset/Abstract are sampled from the photos themselves (Sunset from the
  // upper "sky" band, Abstract from the whole-image dominant) rather than
  // hand-tuned — see tools that generated assets/wallpapers/{sunset,abstract}.
  'Sunset': [
    Color(0xFFCE9D2A), // 01 golden_sun_clouds
    Color(0xFF825328), // 02 golden_cloudscape
    Color(0xFF85A5B0), // 03 sunrays_clouds
    Color(0xFFA1410A), // 04 golden_hour_sea
    Color(0xFF87888C), // 05 orange_blue_sea
    Color(0xFFA2512B), // 06 orange_cloud_silhouette
    Color(0xFF7C4138), // 07 red_sun_horizon
    Color(0xFF6E4B71), // 08 calm_golden_sea
    Color(0xFF194D55), // 09 dramatic_horizon
    Color(0xFF68839A), // 10 golden_sea_pastel
    Color(0xFF7483A5), // 11 pink_purple_sea
    Color(0xFF52477F), // 12 violet_pink_sky
    Color(0xFF0E4F8A), // 13 pink_blue_clouds
    Color(0xFF7483BF), // 14 violet_ocean
    Color(0xFF577BB7), // 15 teal_seashore
    Color(0xFF86503D), // 16 twilight_clouds
  ],
  'Abstract': [
    Color(0xFF51289B), // 01 purple_glow
    Color(0xFF958BDC), // 02 lavender_haze
    Color(0xFFA4A3C8), // 03 blue_pink_mist
    Color(0xFF1C2990), // 04 indigo_folds
    Color(0xFF2A0B66), // 05 indigo_waves
    Color(0xFF5FB3CC), // 06 teal_marble
    Color(0xFFDA82AB), // 07 magenta_gradient
    Color(0xFFBFACC2), // 08 spectrum_gradient
    Color(0xFFD33C56), // 09 warm_gradient
    Color(0xFF69201E), // 10 ember_glow
    Color(0xFF1F41A1), // 11 ribbon_waves
    Color(0xFF6C2A82), // 12 flame_waves
    Color(0xFF8680CF), // 13 glossy_rings
    Color(0xFF6D629D), // 14 chrome_swirl
    Color(0xFF98298E), // 15 violet_swirl
    Color(0xFF334648), // 16 teal_orange_burst
  ],
};

/// A single representative color for a wallpaper, used by the inset
/// ring's color derivation. Photo-backed categories use a per-category
/// palette; a custom or procedural solid hands back its fill color.
/// Falls back to neutral grey if the decoration shape is unknown.
Color wallpaperRepresentativeColor(String category, int index,
    {Color? solidColor}) {
  final canonical = canonicalWallpaperCategory(category);
  if (canonical == 'Solid' && solidColor != null) return solidColor;
  if (isPhotoWallpaperCategory(canonical)) {
    final key = canonical == 'Favorite' ? 'macOS' : canonical;
    final palette = _photoCategoryColors[key];
    if (palette != null && palette.isNotEmpty) {
      return palette[index.clamp(0, palette.length - 1)];
    }
  }
  // The only non-photo decoration left is the procedural Solid fill.
  final dec = wallpaperDecoration(canonical, index);
  if (dec.color != null) return dec.color!;
  return const Color(0xFF606070);
}
