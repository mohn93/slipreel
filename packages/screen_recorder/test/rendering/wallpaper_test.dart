import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/wallpaper.dart';

void main() {
  group('wallpaperRepresentativeColor', () {
    test('LinearGradient wallpapers return the first stop', () {
      // macOS, Spring, and Sunset are all LinearGradients. We don't
      // pin specific colors (the seed is hash-based and could shift)
      // — just that the returned color matches the first stop.
      for (final cat in ['macOS', 'Spring', 'Sunset']) {
        final dec = wallpaperDecoration(cat, 0);
        final gradient = dec.gradient as LinearGradient;
        expect(
          wallpaperRepresentativeColor(cat, 0),
          gradient.colors.first,
          reason: '$cat should hand back the LinearGradient first stop',
        );
      }
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
  });
}
