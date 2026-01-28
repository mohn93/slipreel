import 'dart:ui';
import 'package:flutter/painting.dart';

/// Represents a frame style that can be applied to a window/screen recording.
///
/// Includes visual properties like padding, corner radius, shadows, colors,
/// and borders to create professional-looking frames around recordings.
class WindowFrame {
  /// Name of the frame style
  final String name;

  /// Padding around the content
  final EdgeInsets padding;

  /// Corner radius for rounded corners
  final double cornerRadius;

  /// Shadow blur radius
  final double shadowBlur;

  /// Shadow offset from the content
  final Offset shadowOffset;

  /// Shadow color
  final Color shadowColor;

  /// Background color behind the content (null for transparent)
  final Color? backgroundColor;

  /// Border width
  final double borderWidth;

  /// Border color (null for no border)
  final Color? borderColor;

  const WindowFrame({
    required this.name,
    required this.padding,
    required this.cornerRadius,
    required this.shadowBlur,
    required this.shadowOffset,
    required this.shadowColor,
    this.backgroundColor,
    required this.borderWidth,
    this.borderColor,
  });

  /// Creates a frame with no decorations (transparent, no padding or effects)
  factory WindowFrame.none() {
    return const WindowFrame(
      name: 'None',
      padding: EdgeInsets.zero,
      cornerRadius: 0.0,
      shadowBlur: 0.0,
      shadowOffset: Offset.zero,
      shadowColor: Color(0x00000000),
      backgroundColor: null,
      borderWidth: 0.0,
      borderColor: null,
    );
  }

  /// Creates a rounded frame with soft shadows and white background
  factory WindowFrame.rounded() {
    return const WindowFrame(
      name: 'Rounded',
      padding: EdgeInsets.all(40),
      cornerRadius: 16.0,
      shadowBlur: 40.0,
      shadowOffset: Offset(0, 8),
      shadowColor: Color(0x26000000), // 15% opacity black
      backgroundColor: Color(0xFFFFFFFF), // White
      borderWidth: 1.0,
      borderColor: Color(0x1A000000), // 10% opacity black
    );
  }

  /// Creates a modern frame with large padding and prominent shadows
  factory WindowFrame.modern() {
    return const WindowFrame(
      name: 'Modern',
      padding: EdgeInsets.all(60),
      cornerRadius: 24.0,
      shadowBlur: 60.0,
      shadowOffset: Offset(0, 12),
      shadowColor: Color(0x33000000), // 20% opacity black
      backgroundColor: Color(0xFFF5F5F5), // Light gray
      borderWidth: 0.0,
      borderColor: null,
    );
  }

  /// Creates a minimal frame with subtle effects
  factory WindowFrame.minimal() {
    return const WindowFrame(
      name: 'Minimal',
      padding: EdgeInsets.all(30),
      cornerRadius: 8.0,
      shadowBlur: 20.0,
      shadowOffset: Offset(0, 4),
      shadowColor: Color(0x1A000000), // 10% opacity black
      backgroundColor: null,
      borderWidth: 1.0,
      borderColor: Color(0x0D000000), // 5% opacity black
    );
  }

  /// Returns a list of all available frame templates
  static List<WindowFrame> get templates => [
        WindowFrame.none(),
        WindowFrame.rounded(),
        WindowFrame.modern(),
        WindowFrame.minimal(),
      ];

  /// Creates a copy of this frame with the given properties replaced
  WindowFrame copyWith({
    String? name,
    EdgeInsets? padding,
    double? cornerRadius,
    double? shadowBlur,
    Offset? shadowOffset,
    Color? shadowColor,
    Color? backgroundColor,
    double? borderWidth,
    Color? borderColor,
  }) {
    return WindowFrame(
      name: name ?? this.name,
      padding: padding ?? this.padding,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      shadowBlur: shadowBlur ?? this.shadowBlur,
      shadowOffset: shadowOffset ?? this.shadowOffset,
      shadowColor: shadowColor ?? this.shadowColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      borderWidth: borderWidth ?? this.borderWidth,
      borderColor: borderColor ?? this.borderColor,
    );
  }

  /// Converts this frame to a JSON map
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'padding': {
        'left': padding.left,
        'top': padding.top,
        'right': padding.right,
        'bottom': padding.bottom,
      },
      'cornerRadius': cornerRadius,
      'shadowBlur': shadowBlur,
      'shadowOffset': {
        'dx': shadowOffset.dx,
        'dy': shadowOffset.dy,
      },
      'shadowColor': shadowColor.value,
      'backgroundColor': backgroundColor?.value,
      'borderWidth': borderWidth,
      'borderColor': borderColor?.value,
    };
  }

  /// Creates a frame from a JSON map
  factory WindowFrame.fromJson(Map<String, dynamic> json) {
    final paddingJson = json['padding'] as Map<String, dynamic>;
    final shadowOffsetJson = json['shadowOffset'] as Map<String, dynamic>;

    return WindowFrame(
      name: json['name'] as String,
      padding: EdgeInsets.only(
        left: (paddingJson['left'] as num).toDouble(),
        top: (paddingJson['top'] as num).toDouble(),
        right: (paddingJson['right'] as num).toDouble(),
        bottom: (paddingJson['bottom'] as num).toDouble(),
      ),
      cornerRadius: (json['cornerRadius'] as num).toDouble(),
      shadowBlur: (json['shadowBlur'] as num).toDouble(),
      shadowOffset: Offset(
        (shadowOffsetJson['dx'] as num).toDouble(),
        (shadowOffsetJson['dy'] as num).toDouble(),
      ),
      shadowColor: Color(json['shadowColor'] as int),
      backgroundColor: json['backgroundColor'] != null
          ? Color(json['backgroundColor'] as int)
          : null,
      borderWidth: (json['borderWidth'] as num).toDouble(),
      borderColor: json['borderColor'] != null
          ? Color(json['borderColor'] as int)
          : null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is WindowFrame &&
        other.name == name &&
        other.padding == padding &&
        other.cornerRadius == cornerRadius &&
        other.shadowBlur == shadowBlur &&
        other.shadowOffset == shadowOffset &&
        other.shadowColor == shadowColor &&
        other.backgroundColor == backgroundColor &&
        other.borderWidth == borderWidth &&
        other.borderColor == borderColor;
  }

  @override
  int get hashCode {
    return Object.hash(
      name,
      padding,
      cornerRadius,
      shadowBlur,
      shadowOffset,
      shadowColor,
      backgroundColor,
      borderWidth,
      borderColor,
    );
  }

  @override
  String toString() {
    return 'WindowFrame('
        'name: $name, '
        'padding: $padding, '
        'cornerRadius: $cornerRadius, '
        'shadowBlur: $shadowBlur, '
        'shadowOffset: $shadowOffset, '
        'shadowColor: $shadowColor, '
        'backgroundColor: $backgroundColor, '
        'borderWidth: $borderWidth, '
        'borderColor: $borderColor'
        ')';
  }
}
