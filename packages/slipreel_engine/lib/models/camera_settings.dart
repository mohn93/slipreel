import 'package:slipreel_engine/models/camera_shape.dart';

/// The global look of the camera bubble for one recording. Stored on
/// `EditorProjectState`; shape/roundness/style are deliberately global
/// (only position/size/visibility live on each `CameraRegion`).
class CameraSettings {
  /// Master show/hide for the camera in this project. Independent of
  /// whether a `.camera.mov` sidecar exists.
  final bool enabled;

  final CameraShape shape;

  /// Corner-radius factor 0..1 for the rectangular shapes. Ignored when
  /// [shape] is [CameraShape.circle] (always fully round).
  final double roundness;

  /// Horizontal flip. Default true — most webcams read more natural
  /// mirrored, matching how the user sees themselves while recording.
  final bool mirror;

  /// Border thickness in canvas pixels (0 = no border).
  final double borderWidth;

  /// Border color as a 32-bit ARGB int (matches `Color.value`).
  final int borderColor;

  final bool shadow;

  /// 0..1 overall opacity of the bubble.
  final double opacity;

  const CameraSettings({
    this.enabled = true,
    this.shape = CameraShape.circle,
    this.roundness = 1.0,
    this.mirror = true,
    this.borderWidth = 0.0,
    this.borderColor = 0xFFFFFFFF,
    this.shadow = true,
    this.opacity = 1.0,
  });

  CameraSettings copyWith({
    bool? enabled,
    CameraShape? shape,
    double? roundness,
    bool? mirror,
    double? borderWidth,
    int? borderColor,
    bool? shadow,
    double? opacity,
  }) =>
      CameraSettings(
        enabled: enabled ?? this.enabled,
        shape: shape ?? this.shape,
        roundness: roundness ?? this.roundness,
        mirror: mirror ?? this.mirror,
        borderWidth: borderWidth ?? this.borderWidth,
        borderColor: borderColor ?? this.borderColor,
        shadow: shadow ?? this.shadow,
        opacity: opacity ?? this.opacity,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'shape': shape.name,
        'roundness': roundness,
        'mirror': mirror,
        'borderWidth': borderWidth,
        'borderColor': borderColor,
        'shadow': shadow,
        'opacity': opacity,
      };

  factory CameraSettings.fromJson(Map<String, dynamic> json) {
    CameraShape shape = CameraShape.circle;
    final raw = json['shape'];
    if (raw is String) {
      for (final s in CameraShape.values) {
        if (s.name == raw) {
          shape = s;
          break;
        }
      }
    }
    double clamp01(Object? v, double fallback) =>
        (v is num && v.isFinite) ? v.toDouble().clamp(0.0, 1.0) : fallback;
    return CameraSettings(
      enabled: json['enabled'] as bool? ?? true,
      shape: shape,
      roundness: clamp01(json['roundness'], 1.0),
      mirror: json['mirror'] as bool? ?? true,
      borderWidth: (json['borderWidth'] is num &&
              (json['borderWidth'] as num).isFinite)
          ? (json['borderWidth'] as num).toDouble().clamp(0.0, 64.0)
          : 0.0,
      borderColor: (json['borderColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
      shadow: json['shadow'] as bool? ?? true,
      opacity: clamp01(json['opacity'], 1.0),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraSettings &&
          other.enabled == enabled &&
          other.shape == shape &&
          other.roundness == roundness &&
          other.mirror == mirror &&
          other.borderWidth == borderWidth &&
          other.borderColor == borderColor &&
          other.shadow == shadow &&
          other.opacity == opacity;

  @override
  int get hashCode => Object.hash(enabled, shape, roundness, mirror,
      borderWidth, borderColor, shadow, opacity);
}
