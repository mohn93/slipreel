import 'package:flutter/animation.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/rendering/animation_style.dart';

/// Either a preset pick (one of [ScreenAnimationStyle]) or a custom
/// cubic bezier with an optional badge-tween-duration override. The
/// inspector picker writes one of these into the playback screen's
/// state on every change.
class ScreenAnimationConfig {
  const ScreenAnimationConfig.preset(ScreenAnimationStyle preset)
      : _preset = preset,
        _customCurve = null,
        _customBadgeDuration = null;

  const ScreenAnimationConfig.custom({
    required CubicBezierCurve curve,
    Duration? badgeDuration,
  })  : _preset = null,
        _customCurve = curve,
        _customBadgeDuration = badgeDuration;

  final ScreenAnimationStyle? _preset;
  final CubicBezierCurve? _customCurve;
  final Duration? _customBadgeDuration;

  bool get isCustom => _customCurve != null;
  ScreenAnimationStyle? get preset => _preset;
  CubicBezierCurve? get customCurve => _customCurve;

  Curve get badgeCurve =>
      _customCurve?.toFlutterCurve() ?? _preset!.badgeCurve;

  Curve get rampCurve =>
      _customCurve?.toFlutterCurve() ?? _preset!.rampCurve;

  Duration get badgeDuration =>
      _customBadgeDuration ??
      _preset?.badgeDuration ??
      ScreenAnimationStyle.smooth.badgeDuration;

  Map<String, dynamic> toJson() {
    if (_preset != null) {
      return {'preset': _preset.name};
    }
    return {
      'curve': _customCurve!.toJson(),
      if (_customBadgeDuration != null)
        'badgeDurationMicros': _customBadgeDuration.inMicroseconds,
    };
  }

  factory ScreenAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      final preset = ScreenAnimationStyle.values.firstWhere(
        (e) => e.name == presetName,
        orElse: () => ScreenAnimationStyle.smooth,
      );
      return ScreenAnimationConfig.preset(preset);
    }
    final curve = AnimationCurve.fromJson(
        json['curve'] as Map<String, dynamic>) as CubicBezierCurve;
    final micros = json['badgeDurationMicros'] as int?;
    return ScreenAnimationConfig.custom(
      curve: curve,
      badgeDuration: micros != null ? Duration(microseconds: micros) : null,
    );
  }
}

class CursorAnimationConfig {
  const CursorAnimationConfig.preset(CursorAnimationStyle preset)
      : _preset = preset,
        _customCurve = null,
        _customWindow = null;

  const CursorAnimationConfig.custom({
    required CubicBezierCurve curve,
    required Duration window,
  })  : _preset = null,
        _customCurve = curve,
        _customWindow = window;

  final CursorAnimationStyle? _preset;
  final CubicBezierCurve? _customCurve;
  final Duration? _customWindow;

  bool get isCustom => _customCurve != null;
  CursorAnimationStyle? get preset => _preset;
  CubicBezierCurve? get customCurve => _customCurve;

  Duration get window => _customWindow ?? _preset!.fir.window;
  Curve get firCurve => _customCurve?.toFlutterCurve() ?? _preset!.fir.curve;

  Map<String, dynamic> toJson() {
    if (_preset != null) {
      return {'preset': _preset.name};
    }
    return {
      'curve': _customCurve!.toJson(),
      'windowMicros': _customWindow!.inMicroseconds,
    };
  }

  factory CursorAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      final preset = CursorAnimationStyle.values.firstWhere(
        (e) => e.name == presetName,
        orElse: () => CursorAnimationStyle.smooth,
      );
      return CursorAnimationConfig.preset(preset);
    }
    final curve = AnimationCurve.fromJson(
        json['curve'] as Map<String, dynamic>) as CubicBezierCurve;
    return CursorAnimationConfig.custom(
      curve: curve,
      window: Duration(microseconds: json['windowMicros'] as int),
    );
  }
}
