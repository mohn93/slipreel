import 'package:flutter/animation.dart';

/// Either a named preset (resolved against the active style enums or
/// the saved-curve library) or a user-authored cubic bezier.
sealed class AnimationCurve {
  const AnimationCurve();

  Curve toFlutterCurve();
  Map<String, dynamic> toJson();

  static AnimationCurve fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'preset':
        return PresetCurve(presetId: json['presetId'] as String);
      case 'bezier':
        return CubicBezierCurve(
          x1: (json['x1'] as num).toDouble(),
          y1: (json['y1'] as num).toDouble(),
          x2: (json['x2'] as num).toDouble(),
          y2: (json['y2'] as num).toDouble(),
        );
      default:
        throw FormatException('Unknown AnimationCurve type: $type');
    }
  }
}

class PresetCurve extends AnimationCurve {
  const PresetCurve({required this.presetId});
  final String presetId;

  @override
  Curve toFlutterCurve() {
    // Preset resolution lives in the ScreenAnimationConfig /
    // CursorAnimationConfig wrappers — they know which enum the id
    // belongs to. PresetCurve.toFlutterCurve should never be called
    // directly. In debug builds we assert; in release we fall back to
    // linear so we never crash a render pass.
    assert(false,
        'PresetCurve.toFlutterCurve called directly — resolve presets '
        'via ScreenAnimationConfig or CursorAnimationConfig first');
    return Curves.linear;
  }

  @override
  Map<String, dynamic> toJson() => {'type': 'preset', 'presetId': presetId};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresetCurve && presetId == other.presetId;

  @override
  int get hashCode => presetId.hashCode;
}

class CubicBezierCurve extends AnimationCurve {
  const CubicBezierCurve({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  @override
  Curve toFlutterCurve() => Cubic(x1, y1, x2, y2);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'bezier',
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
      };

  CubicBezierCurve copyWith({double? x1, double? y1, double? x2, double? y2}) {
    return CubicBezierCurve(
      x1: x1 ?? this.x1,
      y1: y1 ?? this.y1,
      x2: x2 ?? this.x2,
      y2: y2 ?? this.y2,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CubicBezierCurve &&
          x1 == other.x1 &&
          y1 == other.y1 &&
          x2 == other.x2 &&
          y2 == other.y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);
}
