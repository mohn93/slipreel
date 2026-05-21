import 'package:flutter/physics.dart';

/// Spring parameters for the cursor's motion-smoothing chase.
///
/// The renderer feeds a `SpringSimulation` per axis, retargeted each
/// frame to the recording's raw cursor position. [stiffness] controls
/// how forcefully the spring pulls toward the target (bigger = snappier,
/// less perceived smoothing). [damping] is the damping *ratio* — 1.0 is
/// critically damped (no overshoot, fastest non-oscillating settle),
/// values below 1.0 overshoot and ring, values above 1.0 are over-
/// damped and slower. Mass scales both — keep it at 1.0 unless you
/// really know what you want.
///
/// The sentinel [snap] disables smoothing entirely (cursor rendered at
/// its raw recorded position every frame). [isSnap] checks for it
/// without exposing the magic value.
class MotionSpring {
  const MotionSpring({
    required this.stiffness,
    required this.damping,
    this.mass = 1.0,
  });

  final double stiffness;
  final double damping;
  final double mass;

  /// Sentinel for "no smoothing — render the raw recorded position".
  /// Negative stiffness can never come out of the slider, so this is
  /// always distinguishable from a user-configured spring.
  static const MotionSpring snap =
      MotionSpring(stiffness: -1, damping: -1);

  bool get isSnap => stiffness <= 0;

  SpringDescription toDescription() => SpringDescription.withDampingRatio(
        mass: mass,
        stiffness: stiffness,
        ratio: damping,
      );

  MotionSpring copyWith({double? stiffness, double? damping, double? mass}) =>
      MotionSpring(
        stiffness: stiffness ?? this.stiffness,
        damping: damping ?? this.damping,
        mass: mass ?? this.mass,
      );

  Map<String, dynamic> toJson() => {
        'stiffness': stiffness,
        'damping': damping,
        'mass': mass,
      };

  factory MotionSpring.fromJson(Map<String, dynamic> json) => MotionSpring(
        stiffness: (json['stiffness'] as num).toDouble(),
        damping: (json['damping'] as num).toDouble(),
        mass: (json['mass'] as num?)?.toDouble() ?? 1.0,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MotionSpring &&
          other.stiffness == stiffness &&
          other.damping == damping &&
          other.mass == mass);

  @override
  int get hashCode => Object.hash(stiffness, damping, mass);
}

/// Spring parameters for the cursor click press-pulse — the size
/// shrink/snap animation that plays when the user presses and releases
/// the mouse button. Evaluated in closed form by feeding the press
/// and release timestamps into a `SpringSimulation`, so there's no
/// per-frame state and scrubbing the playhead is exact.
///
/// Defaults: critically damped (no bounce), stiffness ~350 — quick and
/// readable. Drop damping below 1.0 to add bounce on release.
class ClickSpring {
  const ClickSpring({
    required this.stiffness,
    required this.damping,
    this.mass = 1.0,
  });

  final double stiffness;
  final double damping;
  final double mass;

  /// Default tuning: snappy, no bounce. Press and release both settle
  /// in ~150–200 ms.
  static const ClickSpring snappy =
      ClickSpring(stiffness: 350, damping: 1.0);

  SpringDescription toDescription() => SpringDescription.withDampingRatio(
        mass: mass,
        stiffness: stiffness,
        ratio: damping,
      );

  ClickSpring copyWith({double? stiffness, double? damping, double? mass}) =>
      ClickSpring(
        stiffness: stiffness ?? this.stiffness,
        damping: damping ?? this.damping,
        mass: mass ?? this.mass,
      );

  Map<String, dynamic> toJson() => {
        'stiffness': stiffness,
        'damping': damping,
        'mass': mass,
      };

  factory ClickSpring.fromJson(Map<String, dynamic> json) => ClickSpring(
        stiffness: (json['stiffness'] as num).toDouble(),
        damping: (json['damping'] as num).toDouble(),
        mass: (json['mass'] as num?)?.toDouble() ?? 1.0,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ClickSpring &&
          other.stiffness == stiffness &&
          other.damping == damping &&
          other.mass == mass);

  @override
  int get hashCode => Object.hash(stiffness, damping, mass);
}
