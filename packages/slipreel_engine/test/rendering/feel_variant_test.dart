import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/feel_variant.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';

void main() {
  test('candidate 0 is the non-experimental Default', () {
    final d = FeelVariant.candidates.first;
    expect(d.label, 'Default');
    expect(d.screen.experimental, isFalse);
    expect(d.cursor.experimental, isFalse);
    expect(d.tuning, MotionTuningPreset.defaults);
  });

  test('there are at least 3 candidates and the Studio ones are experimental', () {
    expect(FeelVariant.candidates.length, greaterThanOrEqualTo(3));
    final studio = FeelVariant.candidates.skip(1);
    for (final v in studio) {
      expect(v.screen.experimental, isTrue, reason: v.label);
      expect(v.cursor.experimental, isTrue, reason: v.label);
    }
  });
}
