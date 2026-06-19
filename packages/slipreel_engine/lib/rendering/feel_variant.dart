import 'package:flutter/foundation.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';

/// A named bundle of screen + cursor + motion-tuning settings, used by the
/// debug Feel A/B Lab to flip a whole "feel" with one control. Candidate 0
/// is the shipping Default; the rest are Screen-Studio-aimed experiments.
@immutable
class FeelVariant {
  const FeelVariant({
    required this.label,
    required this.screen,
    required this.cursor,
    required this.tuning,
  });

  final String label;
  final ScreenAnimationStyle screen;
  final CursorAnimationStyle cursor;
  final MotionTuningPreset tuning;

  static const List<FeelVariant> candidates = [
    FeelVariant(
      label: 'Default',
      screen: ScreenAnimationStyle.smooth,
      cursor: CursorAnimationStyle.smooth,
      tuning: MotionTuningPreset.defaults,
    ),
    FeelVariant(
      label: 'Studio Soft',
      screen: ScreenAnimationStyle.studioSoft,
      cursor: CursorAnimationStyle.studioSoft,
      tuning: MotionTuningPreset.cinematic,
    ),
    FeelVariant(
      label: 'Studio Snappy',
      screen: ScreenAnimationStyle.studioSnappy,
      cursor: CursorAnimationStyle.studioSnappy,
      tuning: MotionTuningPreset.snappy,
    ),
  ];
}
