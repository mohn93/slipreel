import 'tilt3d.dart';
import 'zoom_movement.dart';
import 'zoom_region.dart';

/// A zoom's presentation style: its 3D tilt plus its camera movement, taken
/// together. The inspector offers a few named presets ([presets]) and the
/// individual tilt / movement controls act as overrides on top of them.
///
/// Also the per-project default for newly created zooms
/// (`EditorProjectState.defaultZoomLook`).
class ZoomLook {
  const ZoomLook({
    this.tilt = const Tilt3D(),
    this.movement = const ZoomMovement(),
  });

  final Tilt3D tilt;
  final ZoomMovement movement;

  /// 2D, static hold.
  static const ZoomLook flat = ZoomLook();

  /// Subtle lean, static hold. The default for new zooms.
  static const ZoomLook classic = ZoomLook(
    tilt: Tilt3D(style: ZoomTiltStyle.subtle),
  );

  /// Subtle lean with a slow push-in across the hold.
  static const ZoomLook cinematic = ZoomLook(
    tilt: Tilt3D(style: ZoomTiltStyle.subtle),
    movement: ZoomMovement(kind: ZoomMovementKind.pushIn),
  );

  /// Dramatic lean with a subtle sweep. The sum stays under the combined
  /// yaw cap (`kMaxCombinedYawDeg`).
  static const ZoomLook showcase = ZoomLook(
    tilt: Tilt3D(style: ZoomTiltStyle.dramatic),
    movement: ZoomMovement(kind: ZoomMovementKind.sweep),
  );

  /// Presets in inspector order.
  static const List<ZoomLook> presets = [flat, classic, cinematic, showcase];

  /// The preset's display name, or null for a combination that is not one
  /// of [presets] (including any manual tilt angle).
  String? get presetName {
    if (this == flat) return 'Flat';
    if (this == classic) return 'Classic';
    if (this == cinematic) return 'Cinematic';
    if (this == showcase) return 'Showcase';
    return null;
  }

  /// The look a region currently has.
  factory ZoomLook.of(ZoomRegion region) =>
      ZoomLook(tilt: region.tilt, movement: region.movement);

  /// [region] restyled with this look; nothing else changes.
  ZoomRegion applyTo(ZoomRegion region) =>
      region.copyWith(tilt: tilt, movement: movement);

  Map<String, dynamic> toJson() => {
        'tilt': tilt.toJson(),
        'movement': movement.toJson(),
      };

  /// Missing sections decode to their model defaults (2D, no movement).
  factory ZoomLook.fromJson(Map<String, dynamic> json) => ZoomLook(
        tilt: json['tilt'] is Map
            ? Tilt3D.fromJson((json['tilt'] as Map).cast<String, dynamic>())
            : const Tilt3D(),
        movement: json['movement'] is Map
            ? ZoomMovement.fromJson(
                (json['movement'] as Map).cast<String, dynamic>())
            : const ZoomMovement(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomLook &&
          runtimeType == other.runtimeType &&
          tilt == other.tilt &&
          movement == other.movement;

  @override
  int get hashCode => Object.hash(tilt, movement);
}
