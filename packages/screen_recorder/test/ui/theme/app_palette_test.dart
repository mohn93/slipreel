import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

void main() {
  group('AppPalette named constants', () {
    test('midnight / carbon / obsidian are pairwise distinct', () {
      expect(AppPalette.midnight, isNot(AppPalette.carbon));
      expect(AppPalette.midnight, isNot(AppPalette.obsidian));
      expect(AppPalette.carbon, isNot(AppPalette.obsidian));
    });

    test('every named constant has all 10 role fields non-null', () {
      for (final p in [
        AppPalette.midnight,
        AppPalette.carbon,
        AppPalette.obsidian,
      ]) {
        expect(p.appBackground, isNotNull);
        expect(p.surfaceLow, isNotNull);
        expect(p.surfaceElevated, isNotNull);
        expect(p.surfaceCard, isNotNull);
        expect(p.dividerSubtle, isNotNull);
        expect(p.dividerStrong, isNotNull);
        expect(p.accent, isNotNull);
        expect(p.accentMuted, isNotNull);
        expect(p.textPrimary, isNotNull);
        expect(p.textSecondary, isNotNull);
      }
    });
  });

  group('AppPalette.byId', () {
    test('returns the matching constant for every PaletteId', () {
      expect(AppPalette.byId(PaletteId.midnight), AppPalette.midnight);
      expect(AppPalette.byId(PaletteId.carbon), AppPalette.carbon);
      expect(AppPalette.byId(PaletteId.obsidian), AppPalette.obsidian);
    });
  });

  group('AppPalette.copyWith', () {
    test('replaces only the named field', () {
      const replacement = Color(0xFFFF0000);
      final next = AppPalette.midnight.copyWith(accent: replacement);
      expect(next.accent, replacement);
      expect(next.appBackground, AppPalette.midnight.appBackground);
      expect(next.surfaceElevated, AppPalette.midnight.surfaceElevated);
      expect(next.dividerSubtle, AppPalette.midnight.dividerSubtle);
    });
  });

  group('AppPalette.lerp', () {
    test('t=0 returns this', () {
      final result = AppPalette.midnight.lerp(AppPalette.carbon, 0.0);
      expect(result.appBackground, AppPalette.midnight.appBackground);
    });

    test('t=1 returns the other palette', () {
      final result = AppPalette.midnight.lerp(AppPalette.carbon, 1.0);
      expect(result.appBackground, AppPalette.carbon.appBackground);
    });

    test('null other returns this unchanged', () {
      final result = AppPalette.midnight.lerp(null, 0.5);
      expect(result.appBackground, AppPalette.midnight.appBackground);
    });
  });

  group('AppPalette.toColorScheme', () {
    test('maps palette roles to the matching ColorScheme slots', () {
      final scheme = AppPalette.midnight.toColorScheme();
      expect(scheme.brightness, Brightness.dark);
      expect(scheme.primary, AppPalette.midnight.accent);
      expect(scheme.background, AppPalette.midnight.appBackground);
      expect(scheme.surface, AppPalette.midnight.surfaceElevated);
      expect(scheme.outlineVariant, AppPalette.midnight.dividerSubtle);
    });
  });
}
