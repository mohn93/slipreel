import 'package:flutter/animation.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/spring_config.dart';

/// Either a preset pick (one of [ScreenAnimationStyle]) or a custom
/// cubic bezier with an optional badge-tween-duration override. The
/// inspector picker writes one of these into the playback screen's
/// state on every change.
class ScreenAnimationConfig {
  const ScreenAnimationConfig.preset(ScreenAnimationStyle preset)
      : _preset = preset,
        _customCurve = null,
        _customBadgeDuration = null,
        _customFlutterCurve = null;

  ScreenAnimationConfig.custom({
    required CubicBezierCurve curve,
    Duration? badgeDuration,
  })  : _preset = null,
        _customCurve = curve,
        _customBadgeDuration = badgeDuration,
        _customFlutterCurve = curve.toFlutterCurve();

  /// Default badge tween duration when a `.custom` config doesn't
  /// supply one. Matches the Smooth preset's badge duration so the
  /// transition between picking "Smooth" and picking "Custom" with no
  /// duration override doesn't change the feel.
  static const Duration _defaultCustomBadgeDuration =
      Duration(milliseconds: 350);

  // Exactly one of (_preset, _customCurve) is non-null. Enforced by the
  // two named constructors. Resolution accessors below rely on this.
  final ScreenAnimationStyle? _preset;
  final CubicBezierCurve? _customCurve;
  final Duration? _customBadgeDuration;
  final Curve? _customFlutterCurve;

  bool get isCustom => _customCurve != null;
  ScreenAnimationStyle? get preset => _preset;
  CubicBezierCurve? get customCurve => _customCurve;

  Curve get badgeCurve =>
      _customFlutterCurve ?? _preset!.badgeCurve;

  Curve get rampCurve =>
      _customFlutterCurve ?? _preset!.rampCurve;

  Duration get badgeDuration =>
      _customBadgeDuration ??
      _preset?.badgeDuration ??
      _defaultCustomBadgeDuration;

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
      ScreenAnimationStyle? preset;
      for (final s in ScreenAnimationStyle.values) {
        if (s.name == presetName) {
          preset = s;
          break;
        }
      }
      if (preset == null) {
        throw FormatException(
            'Unknown ScreenAnimationStyle preset: $presetName');
      }
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
        _customWindow = null,
        _customFlutterCurve = null,
        _customSpring = null;

  CursorAnimationConfig.custom({
    required CubicBezierCurve curve,
    required Duration window,
  })  : _preset = null,
        _customCurve = curve,
        _customWindow = window,
        _customFlutterCurve = curve.toFlutterCurve(),
        _customSpring = null;

  /// Spring-based custom config. Use this from the Springs section in
  /// the cursor tab — dragging a slider builds a new config of this
  /// shape, preserving (or initialising from) the current motion
  /// spring values without touching the preset enum.
  const CursorAnimationConfig.customSpring({required MotionSpring spring})
      : _preset = null,
        _customCurve = null,
        _customWindow = null,
        _customFlutterCurve = null,
        _customSpring = spring;

  // Exactly one of (_preset, _customCurve, _customSpring) is non-null.
  // Enforced by the named constructors. Resolution accessors below
  // rely on this.
  final CursorAnimationStyle? _preset;
  final CubicBezierCurve? _customCurve;
  final Duration? _customWindow;
  final Curve? _customFlutterCurve;
  final MotionSpring? _customSpring;

  bool get isCustom => _customCurve != null || _customSpring != null;
  bool get isCustomSpring => _customSpring != null;
  CursorAnimationStyle? get preset => _preset;
  CubicBezierCurve? get customCurve => _customCurve;

  Duration get window => _customWindow ?? _preset!.fir.window;
  Curve get firCurve => _customFlutterCurve ?? _preset!.fir.curve;

  /// Active motion spring. Custom-spring configs return their own
  /// override; preset configs return the preset's spring; legacy
  /// custom-curve configs (only loaded from old JSON) fall back to
  /// Smooth — the FIR is gone and re-deriving spring params from a
  /// bezier wouldn't carry meaning.
  MotionSpring get motionSpring =>
      _customSpring ??
      _preset?.motionSpring ??
      CursorAnimationStyle.smooth.motionSpring;

  Map<String, dynamic> toJson() {
    if (_customSpring != null) {
      return {'spring': _customSpring.toJson()};
    }
    if (_preset != null) {
      return {'preset': _preset.name};
    }
    return {
      'curve': _customCurve!.toJson(),
      'windowMicros': _customWindow!.inMicroseconds,
    };
  }

  factory CursorAnimationConfig.fromJson(Map<String, dynamic> json) {
    final springJson = json['spring'] as Map<String, dynamic>?;
    if (springJson != null) {
      return CursorAnimationConfig.customSpring(
        spring: MotionSpring.fromJson(springJson),
      );
    }
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      CursorAnimationStyle? preset;
      for (final s in CursorAnimationStyle.values) {
        if (s.name == presetName) {
          preset = s;
          break;
        }
      }
      if (preset == null) {
        throw FormatException(
            'Unknown CursorAnimationStyle preset: $presetName');
      }
      return CursorAnimationConfig.preset(preset);
    }
    final curve = AnimationCurve.fromJson(
        json['curve'] as Map<String, dynamic>) as CubicBezierCurve;
    final micros = json['windowMicros'];
    if (micros is! int) {
      throw const FormatException(
          'CursorAnimationConfig.fromJson: missing or non-int windowMicros');
    }
    return CursorAnimationConfig.custom(
      curve: curve,
      window: Duration(microseconds: micros),
    );
  }
}
