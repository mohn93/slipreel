import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Push-in extra scale reached at full hold (multiplier = 1 + extra).
const double kPushInSubtleExtra = 0.06;
const double kPushInDramaticExtra = 0.12;

/// Sweep yaw magnitude (degrees) reached at full hold.
const double kSweepSubtleDeg = 5.0;
const double kSweepDramaticDeg = 10.0;

/// Drift focal offset reached at full hold, as a fraction of the video size.
const double kDriftSubtleFrac = 0.04;
const double kDriftDramaticFrac = 0.08;

/// The named camera moves in the v1 library. [none] == today's static hold.
enum ZoomMovementKind { none, pushIn, sweep, drift }

/// Movement magnitude preset, mirroring the tilt vocabulary.
enum ZoomMovementIntensity { subtle, dramatic }

/// One frame's additive movement contribution, on top of the settled
/// (Phase 1) zoom transform. All fields are pre-gated by the ramp so they
/// fade in/out with the zoom.
class ZoomMovementSample {
  const ZoomMovementSample({
    this.scaleMul = 1.0,
    this.extraTiltXRad = 0.0,
    this.extraTiltYRad = 0.0,
    this.focalDriftFrac = Offset.zero,
  });

  /// Multiply the settled zoom factor (1.0 = no change).
  final double scaleMul;

  /// Added to the tilt angles (radians).
  final double extraTiltXRad;
  final double extraTiltYRad;

  /// Added to the focal, expressed as a fraction of the video size (each axis).
  final Offset focalDriftFrac;

  static const ZoomMovementSample identity = ZoomMovementSample();
}

/// Per-zoom camera movement. Lives on [ZoomRegion] next to `Tilt3D`.
///
/// The *direction* of a move is auto-derived from where the focal sits in the
/// frame ([normalizedFocal]); the *magnitude* is set by [intensity] and by how
/// far into the hold the playhead is ([holdProgress]), then gated by the ramp
/// ([rampGate]) so motion is zero at the ramps and full only at the settled
/// hold. Everything is a pure function of position — no state, no path
/// dependence — so preview == scrub == export.
class ZoomMovement {
  const ZoomMovement({
    this.kind = ZoomMovementKind.none,
    this.intensity = ZoomMovementIntensity.subtle,
  });

  final ZoomMovementKind kind;
  final ZoomMovementIntensity intensity;

  bool get isActive => kind != ZoomMovementKind.none;

  /// Ease-in-out (smoothstep) so motion starts and ends gently. This eased
  /// sample of [holdProgress] is the internal "keyframe track" a future editor
  /// could expose.
  static double _ease(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3.0 - 2.0 * c);
  }

  ZoomMovementSample resolveAt({
    required double holdProgress,
    required double rampGate,
    required Offset normalizedFocal,
  }) {
    if (!isActive || rampGate <= 0.0) return ZoomMovementSample.identity;
    final env = _ease(holdProgress) * rampGate.clamp(0.0, 1.0);
    if (env <= 0.0) return ZoomMovementSample.identity;

    switch (kind) {
      case ZoomMovementKind.none:
        return ZoomMovementSample.identity;
      case ZoomMovementKind.pushIn:
        final extra = intensity == ZoomMovementIntensity.dramatic
            ? kPushInDramaticExtra
            : kPushInSubtleExtra;
        return ZoomMovementSample(scaleMul: 1.0 + extra * env);
      case ZoomMovementKind.sweep:
        final deg = intensity == ZoomMovementIntensity.dramatic
            ? kSweepDramaticDeg
            : kSweepSubtleDeg;
        final dir = normalizedFocal.dx >= 0 ? 1.0 : -1.0;
        final rad = deg * (math.pi / 180.0) * dir * env;
        return ZoomMovementSample(extraTiltYRad: rad);
      case ZoomMovementKind.drift:
        final frac = intensity == ZoomMovementIntensity.dramatic
            ? kDriftDramaticFrac
            : kDriftSubtleFrac;
        // Reveal toward the frame center: drift opposite the focal side.
        final dir = normalizedFocal.dx >= 0 ? -1.0 : 1.0;
        return ZoomMovementSample(
            focalDriftFrac: Offset(frac * dir * env, 0.0));
    }
  }

  ZoomMovement copyWith({
    ZoomMovementKind? kind,
    ZoomMovementIntensity? intensity,
  }) {
    return ZoomMovement(
      kind: kind ?? this.kind,
      intensity: intensity ?? this.intensity,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'intensity': intensity.name,
      };

  factory ZoomMovement.fromJson(Map<String, dynamic> json) {
    ZoomMovementKind kind = ZoomMovementKind.none;
    final kindName = json['kind'] as String?;
    if (kindName != null) {
      for (final k in ZoomMovementKind.values) {
        if (k.name == kindName) {
          kind = k;
          break;
        }
      }
    }
    ZoomMovementIntensity intensity = ZoomMovementIntensity.subtle;
    final intName = json['intensity'] as String?;
    if (intName != null) {
      for (final i in ZoomMovementIntensity.values) {
        if (i.name == intName) {
          intensity = i;
          break;
        }
      }
    }
    return ZoomMovement(kind: kind, intensity: intensity);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomMovement &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          intensity == other.intensity;

  @override
  int get hashCode => Object.hash(kind, intensity);
}
