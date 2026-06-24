import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';

void main() {
  group('wallpaperRepresentativeColor', () {
    test('Solid wallpapers return the fill color', () {
      final dec = wallpaperDecoration('Solid', 0);
      expect(wallpaperRepresentativeColor('Solid', 0), dec.color);
    });

    test('photo-backed wallpapers return the hand-tuned palette', () {
      // Photo categories (macOS, Spring, Sunset, Abstract, plus the
      // Favorite alias) pull from a per-category palette rather than
      // gradient stops. Just verify they don't fall back to neutral grey
      // and produce stable, distinct values across indexes.
      for (final cat in ['macOS', 'Spring', 'Sunset', 'Abstract', 'Favorite']) {
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
      for (final cat in ['macOS', 'Spring', 'Sunset', 'Abstract', 'Favorite']) {
        final dec = wallpaperDecoration(cat, 0);
        expect(dec.image, isNotNull,
            reason: '$cat should render a DecorationImage, not a gradient');
        expect(dec.gradient, isNull);
      }
    });

    test('photoWallpaperAsset returns null for procedural categories', () {
      // Solid is the only remaining procedural category.
      expect(photoWallpaperAsset('Solid', 0), isNull);
    });

    test('photoWallpaperAsset returns a path for photo categories', () {
      expect(photoWallpaperAsset('macOS', 0), contains('assets/wallpapers/macos/'));
      expect(photoWallpaperAsset('Spring', 0), contains('assets/wallpapers/spring/'));
      expect(
          photoWallpaperAsset('Sunset', 0), contains('assets/wallpapers/sunset/'));
      expect(photoWallpaperAsset('Abstract', 0),
          contains('assets/wallpapers/abstract/'));
      // Favorite aliases to macOS until a real favoriting system exists.
      expect(photoWallpaperAsset('Favorite', 0), contains('assets/wallpapers/macos/'));
    });
  });

  group('legacy Radial → Abstract migration', () {
    test('canonicalWallpaperCategory rewrites Radial to Abstract', () {
      expect(canonicalWallpaperCategory('Radial'), 'Abstract');
      // Unknown / current categories pass through unchanged.
      expect(canonicalWallpaperCategory('Abstract'), 'Abstract');
      expect(canonicalWallpaperCategory('macOS'), 'macOS');
      expect(canonicalWallpaperCategory('Solid'), 'Solid');
    });

    test('Abstract is a photo-backed category, Radial is not in the list', () {
      expect(kWallpaperCategories, contains('Abstract'));
      expect(kWallpaperCategories, isNot(contains('Radial')));
      expect(isPhotoWallpaperCategory('Abstract'), isTrue);
    });

    test('a legacy Radial reference resolves to the Abstract photos', () {
      // Render path: decoration is image-backed, not a gradient.
      final dec = wallpaperDecoration('Radial', 3);
      expect(dec.image, isNotNull);
      expect(dec.gradient, isNull);
      // Asset + palette match the canonical Abstract category.
      expect(photoWallpaperAsset('Radial', 3),
          equals(photoWallpaperAsset('Abstract', 3)));
      expect(wallpaperRepresentativeColor('Radial', 3),
          equals(wallpaperRepresentativeColor('Abstract', 3)));
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

  group('Solid color override', () {
    test('Solid + solidColor renders that exact color', () {
      final dec = wallpaperDecoration('Solid', 0,
          solidColor: const Color(0xFF123456));
      expect(dec.color, const Color(0xFF123456));
      expect(dec.gradient, isNull);
    });

    test('Solid without solidColor keeps the legacy procedural fill', () {
      final dec = wallpaperDecoration('Solid', 0);
      expect(dec.color, isNotNull);
      expect(dec.color, isNot(const Color(0xFF123456)));
    });

    test('representative color returns the custom solidColor', () {
      expect(
        wallpaperRepresentativeColor('Solid', 0,
            solidColor: const Color(0xFF777777)),
        const Color(0xFF777777),
      );
    });

    test('non-Solid categories ignore solidColor', () {
      final dec = wallpaperDecoration('macOS', 0,
          solidColor: const Color(0xFF123456));
      expect(dec.image, isNotNull); // still a photo
      expect(dec.color, isNull);
    });
  });
}
