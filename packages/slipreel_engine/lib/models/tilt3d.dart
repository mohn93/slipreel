import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Max auto tilt angle (degrees) for the Subtle preset.
const double kTiltSubtleMaxDeg = 4.0;

/// Max auto tilt angle (degrees) for the Dramatic preset.
const double kTiltDramaticMaxDeg = 11.0;

/// The 3D-tilt style of a zoom. [flat] is the 2D case (no tilt); [subtle] and
/// [dramatic] are 3D presets that set the maximum tilt angle.
enum ZoomTiltStyle { flat, subtle, dramatic }

/// Per-zoom 3D tilt configuration. Lives on [ZoomRegion]. [flat] == 2D.
///
/// The tilt *direction* is auto-derived from where the zoom's focal sits in the
/// composed frame; the *magnitude* is set by [style] and ramps with the zoom
/// factor (see [resolveAngles]). [manualAngleX] / [manualAngleY] (degrees), when
/// non-null, override the auto-derived angle on that axis.
class Tilt3D {
  const Tilt3D({
    this.style = ZoomTiltStyle.flat,
    this.manualAngleX,
    this.manualAngleY,
  });

  final ZoomTiltStyle style;
  final double? manualAngleX;
  final double? manualAngleY;

  bool get is3D => style != ZoomTiltStyle.flat;

  double get _maxDeg => switch (style) {
        ZoomTiltStyle.flat => 0.0,
        ZoomTiltStyle.subtle => kTiltSubtleMaxDeg,
        ZoomTiltStyle.dramatic => kTiltDramaticMaxDeg,
      };

  /// Tilt angles in RADIANS for the current frame.
  ///
  /// [normalizedFocal] is the focal's offset from the canvas center, each axis
  /// in `[-1, 1]`. [progress] is the live zoom ramp progress in `[0, 1]` (0 at
  /// rest, 1 at full zoom). Auto: `yRad = nx*max`, `xRad = -ny*max` so the focal
  /// side leans toward the viewer. Manual angles replace the auto value per axis.
  ({double xRad, double yRad}) resolveAngles({
    required Offset normalizedFocal,
    required double progress,
  }) {
    if (!is3D) return (xRad: 0.0, yRad: 0.0);
    const deg2rad = math.pi / 180.0;
    final autoXDeg = -normalizedFocal.dy * _maxDeg;
    final autoYDeg = normalizedFocal.dx * _maxDeg;
    final xDeg = manualAngleX ?? autoXDeg;
    final yDeg = manualAngleY ?? autoYDeg;
    return (xRad: xDeg * deg2rad * progress, yRad: yDeg * deg2rad * progress);
  }

  Tilt3D copyWith({
    ZoomTiltStyle? style,
    double? manualAngleX,
    double? manualAngleY,
    bool clearManual = false,
  }) {
    return Tilt3D(
      style: style ?? this.style,
      manualAngleX: clearManual ? null : (manualAngleX ?? this.manualAngleX),
      manualAngleY: clearManual ? null : (manualAngleY ?? this.manualAngleY),
    );
  }

  Map<String, dynamic> toJson() => {
        'style': style.name,
        if (manualAngleX != null) 'manualAngleX': manualAngleX,
        if (manualAngleY != null) 'manualAngleY': manualAngleY,
      };

  factory Tilt3D.fromJson(Map<String, dynamic> json) {
    final name = json['style'] as String?;
    var style = ZoomTiltStyle.flat;
    if (name != null) {
      for (final s in ZoomTiltStyle.values) {
        if (s.name == name) {
          style = s;
          break;
        }
      }
    }
    return Tilt3D(
      style: style,
      manualAngleX: (json['manualAngleX'] as num?)?.toDouble(),
      manualAngleY: (json['manualAngleY'] as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Tilt3D &&
          runtimeType == other.runtimeType &&
          style == other.style &&
          manualAngleX == other.manualAngleX &&
          manualAngleY == other.manualAngleY;

  @override
  int get hashCode => Object.hash(style, manualAngleX, manualAngleY);
}
