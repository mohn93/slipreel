import 'dart:math';
import 'package:flutter/material.dart';

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

/// Returns a [BoxDecoration] that renders the wallpaper for
/// `(category, index)`. Used by both the picker tiles and the
/// playback canvas so they look identical.
///
/// "Favorite" shares the macOS palette today — there's no real
/// favoriting yet; this keeps the chip non-empty so users can preview
/// it.
BoxDecoration wallpaperDecoration(String category, int index) {
  final r = Random('$category.$index'.hashCode);
  switch (category) {
    case 'macOS':
    case 'Favorite':
      return _macOSGradient(r);
    case 'Spring':
      return _springGradient(r);
    case 'Sunset':
      return _sunsetGradient(r);
    case 'Radial':
      return _radialGradient(r);
    case 'Solid':
      return _solid(r);
    default:
      return _macOSGradient(r);
  }
}

BoxDecoration _macOSGradient(Random r) {
  // Cool blues + slate greys, vaguely Big Sur / Sequoia.
  final hue1 = 200 + r.nextDouble() * 40; // 200–240
  final hue2 = (hue1 + 10 + r.nextDouble() * 30) % 360;
  final c1 = HSLColor.fromAHSL(1, hue1, 0.55, 0.40 + r.nextDouble() * 0.15)
      .toColor();
  final c2 = HSLColor.fromAHSL(1, hue2, 0.45, 0.18 + r.nextDouble() * 0.20)
      .toColor();
  return BoxDecoration(
    gradient: LinearGradient(
      begin: const Alignment(-0.6, -1.0),
      end: const Alignment(0.8, 1.0),
      colors: [c1, c2],
    ),
  );
}

BoxDecoration _springGradient(Random r) {
  // Pastels: greens, mints, soft pinks.
  final pickPink = r.nextBool();
  final hue1 = pickPink ? 320 + r.nextDouble() * 30 : 100 + r.nextDouble() * 50;
  final hue2 = (hue1 + 30 + r.nextDouble() * 40) % 360;
  final c1 = HSLColor.fromAHSL(1, hue1, 0.55, 0.78).toColor();
  final c2 = HSLColor.fromAHSL(1, hue2, 0.50, 0.65).toColor();
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [c1, c2],
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
