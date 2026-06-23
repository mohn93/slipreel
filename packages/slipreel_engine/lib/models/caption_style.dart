import 'package:flutter/painting.dart' show Color;

/// Vertical anchor for the caption block on the output canvas.
enum CaptionPosition {
  top,
  bottom;

  String get label => switch (this) {
        CaptionPosition.top => 'Top',
        CaptionPosition.bottom => 'Bottom',
      };
}

/// How the caption text is separated from the video behind it.
enum CaptionBackground {
  box,
  outline,
  none;

  String get label => switch (this) {
        CaptionBackground.box => 'Box',
        CaptionBackground.outline => 'Outline',
        CaptionBackground.none => 'None',
      };
}

/// Per-project caption look. Mirrors `KeystrokeOverlaySettings` /
/// `CameraSettings` — a global style stored on `EditorProjectState`, applied
/// identically in preview and export.
class CaptionStyle {
  const CaptionStyle({
    this.enabled = false,
    this.position = CaptionPosition.bottom,
    this.fontScale = defaultFontScale,
    this.textColor = const Color(0xFFFFFFFF),
    this.background = CaptionBackground.box,
  });

  static const double minFontScale = 0.5;
  static const double maxFontScale = 2.0;
  static const double defaultFontScale = 1.0;

  /// Whether captions render at all. Toggled in the Captions tab.
  final bool enabled;
  final CaptionPosition position;

  /// Multiplier on the base font size (which derives from canvas height).
  final double fontScale;
  final Color textColor;
  final CaptionBackground background;

  CaptionStyle copyWith({
    bool? enabled,
    CaptionPosition? position,
    double? fontScale,
    Color? textColor,
    CaptionBackground? background,
  }) =>
      CaptionStyle(
        enabled: enabled ?? this.enabled,
        position: position ?? this.position,
        fontScale: fontScale ?? this.fontScale,
        textColor: textColor ?? this.textColor,
        background: background ?? this.background,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'position': position.name,
        'fontScale': fontScale,
        'textColor': textColor.toARGB32(),
        'background': background.name,
      };

  factory CaptionStyle.fromJson(Map<String, dynamic> json) => CaptionStyle(
        enabled: json['enabled'] as bool? ?? false,
        position: CaptionPosition.values
                .where((v) => v.name == json['position'])
                .firstOrNull ??
            CaptionPosition.bottom,
        fontScale:
            (json['fontScale'] as num?)?.toDouble() ?? defaultFontScale,
        textColor: Color((json['textColor'] as num?)?.toInt() ?? 0xFFFFFFFF),
        background: CaptionBackground.values
                .where((v) => v.name == json['background'])
                .firstOrNull ??
            CaptionBackground.box,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptionStyle &&
          other.enabled == enabled &&
          other.position == position &&
          other.fontScale == fontScale &&
          other.textColor == textColor &&
          other.background == background;

  @override
  int get hashCode =>
      Object.hash(enabled, position, fontScale, textColor, background);
}
