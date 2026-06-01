import 'package:flutter/material.dart';

/// Selectable palettes shipped with the app. Persisted via
/// `AppPaletteStore.save(PaletteId.name)`.
enum PaletteId { midnight, carbon, obsidian }

/// Role-based palette installed on `ThemeData.extensions`. Widgets
/// read via the `context.palette.<role>` extension.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.appBackground,
    required this.surfaceLow,
    required this.surfaceElevated,
    required this.surfaceCard,
    required this.dividerSubtle,
    required this.dividerStrong,
    required this.accent,
    required this.accentMuted,
    required this.textPrimary,
    required this.textSecondary,
  });

  final Color appBackground;
  final Color surfaceLow;
  final Color surfaceElevated;
  final Color surfaceCard;
  final Color dividerSubtle;
  final Color dividerStrong;
  final Color accent;
  final Color accentMuted;
  final Color textPrimary;
  final Color textSecondary;

  static const AppPalette midnight = AppPalette(
    appBackground: Color(0xFF050507),
    surfaceLow: Color(0xFF08080C),
    surfaceElevated: Color(0xFF0C0C12),
    surfaceCard: Color(0xFF121218),
    dividerSubtle: Color(0xFF1C1C24),
    dividerStrong: Color(0xFF2A2A36),
    accent: Color(0xFF7C6CFF),
    accentMuted: Color(0x2E7C6CFF), // 18% alpha
    textPrimary: Color(0xFFF2F2F5),
    textSecondary: Color(0xFF9A9AA8),
  );

  static const AppPalette carbon = AppPalette(
    appBackground: Color(0xFF121212),
    surfaceLow: Color(0xFF161616),
    surfaceElevated: Color(0xFF1B1B1B),
    surfaceCard: Color(0xFF222222),
    dividerSubtle: Color(0xFF2C2C2C),
    dividerStrong: Color(0xFF3A3A3A),
    accent: Color(0xFF8B7CFF),
    accentMuted: Color(0x2E8B7CFF),
    textPrimary: Color(0xFFEFEFEF),
    textSecondary: Color(0xFFA0A0A0),
  );

  static const AppPalette obsidian = AppPalette(
    appBackground: Color(0xFF0A0E1A),
    surfaceLow: Color(0xFF0F1626),
    surfaceElevated: Color(0xFF10162A),
    surfaceCard: Color(0xFF171F38),
    dividerSubtle: Color(0xFF1F2A48),
    dividerStrong: Color(0xFF2A3A5C),
    accent: Color(0xFF6C63FF),
    accentMuted: Color(0x2E6C63FF),
    textPrimary: Color(0xFFE8ECF5),
    textSecondary: Color(0xFF8B95B0),
  );

  static AppPalette byId(PaletteId id) => switch (id) {
        PaletteId.midnight => midnight,
        PaletteId.carbon => carbon,
        PaletteId.obsidian => obsidian,
      };

  // ignore: deprecated_member_use
  ColorScheme toColorScheme() => ColorScheme.dark(
        // ignore: deprecated_member_use
        background: appBackground,
        surface: surfaceElevated,
        // ignore: deprecated_member_use
        surfaceVariant: surfaceCard,
        primary: accent,
        primaryContainer: accentMuted,
        // ignore: deprecated_member_use
        onBackground: textPrimary,
        onSurface: textPrimary,
        outline: dividerStrong,
        outlineVariant: dividerSubtle,
        brightness: Brightness.dark,
      );

  @override
  AppPalette copyWith({
    Color? appBackground,
    Color? surfaceLow,
    Color? surfaceElevated,
    Color? surfaceCard,
    Color? dividerSubtle,
    Color? dividerStrong,
    Color? accent,
    Color? accentMuted,
    Color? textPrimary,
    Color? textSecondary,
  }) =>
      AppPalette(
        appBackground: appBackground ?? this.appBackground,
        surfaceLow: surfaceLow ?? this.surfaceLow,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        surfaceCard: surfaceCard ?? this.surfaceCard,
        dividerSubtle: dividerSubtle ?? this.dividerSubtle,
        dividerStrong: dividerStrong ?? this.dividerStrong,
        accent: accent ?? this.accent,
        accentMuted: accentMuted ?? this.accentMuted,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
      );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      appBackground: Color.lerp(appBackground, other.appBackground, t)!,
      surfaceLow: Color.lerp(surfaceLow, other.surfaceLow, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      dividerSubtle: Color.lerp(dividerSubtle, other.dividerSubtle, t)!,
      dividerStrong: Color.lerp(dividerStrong, other.dividerStrong, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPalette &&
      other.appBackground == appBackground &&
      other.surfaceLow == surfaceLow &&
      other.surfaceElevated == surfaceElevated &&
      other.surfaceCard == surfaceCard &&
      other.dividerSubtle == dividerSubtle &&
      other.dividerStrong == dividerStrong &&
      other.accent == accent &&
      other.accentMuted == accentMuted &&
      other.textPrimary == textPrimary &&
      other.textSecondary == textSecondary;

  @override
  int get hashCode => Object.hash(
        appBackground,
        surfaceLow,
        surfaceElevated,
        surfaceCard,
        dividerSubtle,
        dividerStrong,
        accent,
        accentMuted,
        textPrimary,
        textSecondary,
      );
}
