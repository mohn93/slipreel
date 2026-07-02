import 'package:flutter/animation.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';

/// Either a preset pick (one of [ScreenAnimationStyle]) or a custom
/// cubic bezier with an optional badge-tween-duration override. The
/// inspector picker writes one of these into the playback screen's
/// state on every change.
class ScreenAnimationConfig {
  const ScreenAnimationConfig.preset(ScreenAnimationStyle preset)
      : _preset = preset;

  final ScreenAnimationStyle? _preset;

  ScreenAnimationStyle? get preset => _preset;

  Curve get badgeCurve => _preset!.badgeCurve;
  Curve get rampCurve => _preset!.rampCurve;
  Duration get badgeDuration => _preset!.badgeDuration;
  double get rampDurationScale => _preset!.rampDurationScale;

  Map<String, dynamic> toJson() => {'preset': _preset!.name};

  factory ScreenAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      for (final s in ScreenAnimationStyle.values) {
        if (s.name == presetName) return ScreenAnimationConfig.preset(s);
      }
      // Retired #7 experimental presets — migrate to their baked
      // equivalents (Smooth/Focused now embody those feels, so lossless):
      // `studioSnappy` → Focused, anything else (incl. `studioSoft`) →
      // Smooth. Keeps saved projects loading after the enums were removed.
      return ScreenAnimationConfig.preset(
        presetName == 'studioSnappy'
            ? ScreenAnimationStyle.focused
            : ScreenAnimationStyle.smooth,
      );
    }
    // Legacy custom config (curve + badgeDurationMicros) — migrate to Smooth.
    return const ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
  }
}

class CursorAnimationConfig {
  const CursorAnimationConfig.preset(CursorAnimationStyle preset)
      : _preset = preset;

  final CursorAnimationStyle? _preset;

  CursorAnimationStyle? get preset => _preset;

  Duration get window => _preset!.fir.window;
  Curve get firCurve => _preset!.fir.curve;
  MotionSpring get motionSpring => _preset!.motionSpring;
  double get feedforwardStrength => _preset!.feedforwardStrength;
  Duration get pathSmoothingSigma => _preset!.pathSmoothingSigma;

  Map<String, dynamic> toJson() => {'preset': _preset!.name};

  factory CursorAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      for (final s in CursorAnimationStyle.values) {
        if (s.name == presetName) return CursorAnimationConfig.preset(s);
      }
      // Retired #7 experimental presets — migrate to their baked
      // equivalents: `studioSnappy` → Medium, anything else (incl.
      // `studioSoft`) → Smooth. Keeps saved projects loading after the
      // enums were removed.
      return CursorAnimationConfig.preset(
        presetName == 'studioSnappy'
            ? CursorAnimationStyle.medium
            : CursorAnimationStyle.smooth,
      );
    }
    // Legacy custom / custom-spring config (spring, or curve+windowMicros) —
    // migrate to the Smooth preset.
    return const CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CursorAnimationConfig && other._preset == _preset;

  @override
  int get hashCode => _preset.hashCode;
}
