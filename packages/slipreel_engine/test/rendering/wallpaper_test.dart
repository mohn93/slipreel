import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';

void main() {
  group('wallpaperRepresentativeColor', () {
    test('LinearGradient wallpapers return the first stop', () {
      // Sunset is the only remaining LinearGradient category. We
      // don't pin specific colors (the seed is hash-based and could
      // shift) — just that the returned color matches the first stop.
      final dec = wallpaperDecoration('Sunset', 0);
      final gradient = dec.gradient as LinearGradient;
      expect(
        wallpaperRepresentativeColor('Sunset', 0),
        gradient.colors.first,
        reason: 'Sunset should hand back the LinearGradient first stop',
      );
    });

    test('RadialGradient wallpapers return the first stop', () {
      final dec = wallpaperDecoration('Radial', 0);
      final gradient = dec.gradient as RadialGradient;
      expect(
        wallpaperRepresentativeColor('Radial', 0),
        gradient.colors.first,
      );
    });

    test('Solid wallpapers return the fill color', () {
      final dec = wallpaperDecoration('Solid', 0);
      expect(wallpaperRepresentativeColor('Solid', 0), dec.color);
    });

    test('photo-backed wallpapers return the hand-tuned palette', () {
      // Photo categories (macOS, Spring, plus the Favorite alias)
      // pull from a hand-tuned palette rather than gradient stops.
      // Just verify they don't fall back to neutral grey and produce
      // stable, distinct values across indexes.
      for (final cat in ['macOS', 'Spring', 'Favorite']) {
        final c0 = wallpaperRepresentativeColor(cat, 0);
        final c1 = wallpaperRepresentativeColor(cat, 1);
        expect(c0, isNot(const Color(0xFF606070)));
        expect(c1, isNot(const Color(0xFF606070)));
        expect(c0, isNot(equals(c1)),
            reason: '$cat indexes should give different palette colors');
        // Stable: re-querying the same index returns the same color.
        expect(wallpaperRepresentativeColor(cat, 0), c0);
      }
    });

    test('photo-backed wallpaper decorations are image-backed', () {
      for (final cat in ['macOS', 'Spring', 'Favorite']) {
        final dec = wallpaperDecoration(cat, 0);
        expect(dec.image, isNotNull,
            reason: '$cat should render a DecorationImage, not a gradient');
        expect(dec.gradient, isNull);
      }
    });

    test('photoWallpaperAsset returns null for procedural categories', () {
      expect(photoWallpaperAsset('Sunset', 0), isNull);
      expect(photoWallpaperAsset('Radial', 0), isNull);
      expect(photoWallpaperAsset('Solid', 0), isNull);
    });

    test('photoWallpaperAsset returns a path for photo categories', () {
      expect(photoWallpaperAsset('macOS', 0), contains('assets/wallpapers/macos/'));
      expect(photoWallpaperAsset('Spring', 0), contains('assets/wallpapers/spring/'));
      // Favorite aliases to macOS until a real favoriting system exists.
      expect(photoWallpaperAsset('Favorite', 0), contains('assets/wallpapers/macos/'));
    });
  });

  group('wallpaperDecoration thumbnail downsampling', () {
    test('photo thumb decodes via ResizeImage at the requested width', () {
      final dec = wallpaperDecoration('macOS', 0, thumbCacheWidth: 256);
      final image = dec.image!.image;
      expect(image, isA<ResizeImage>());
      expect((image as ResizeImage).width, 256);
      expect(image.imageProvider, isA<AssetImage>());
    });

    test('photo full-res (no thumbCacheWidth) stays a plain AssetImage', () {
      final dec = wallpaperDecoration('macOS', 0);
      expect(dec.image!.image, isA<AssetImage>());
    });

    test('procedural categories ignore thumbCacheWidth (no image)', () {
      final dec = wallpaperDecoration('Solid', 0, thumbCacheWidth: 256);
      expect(dec.image, isNull);
      expect(dec.color, isNotNull);
    });
  });
}
