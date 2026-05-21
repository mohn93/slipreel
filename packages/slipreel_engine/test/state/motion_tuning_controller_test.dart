import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';

void main() {
  group('MotionTuningController', () {
    test('starts at MotionTuning.defaults', () {
      final c = MotionTuningController();
      expect(c.state, same(MotionTuning.defaults));
    });

    test('seeds from a custom initial tuning', () {
      const custom = MotionTuning(cursorAtRestPxPerSec: 120);
      final c = MotionTuningController(initial: custom);
      expect(c.state, same(custom));
    });

    test('usePreset() swaps the state to a named preset', () {
      final c = MotionTuningController();
      c.usePreset(MotionTuningPreset.snappy);
      expect(c.state, same(MotionTuning.snappy));

      c.usePreset(MotionTuningPreset.cinematic);
      expect(c.state, same(MotionTuning.cinematic));

      c.usePreset(MotionTuningPreset.defaults);
      expect(c.state, same(MotionTuning.defaults));
    });

    test('replace() applies an arbitrary MotionTuning (e.g. loaded JSON)', () {
      final c = MotionTuningController();
      const custom = MotionTuning(
        cursorAtRestPxPerSec: 65,
        cursorFeedforwardStrength: 0.4,
      );
      c.replace(custom);
      expect(c.state, same(custom));
    });

    test('preset detection: matchesPreset returns the named preset when '
        'state is equal to it; null for a custom one', () {
      final c = MotionTuningController();
      expect(c.activePreset, MotionTuningPreset.defaults);

      c.usePreset(MotionTuningPreset.snappy);
      expect(c.activePreset, MotionTuningPreset.snappy);

      // Custom tuning that doesn't match any preset.
      c.replace(const MotionTuning(cursorAtRestPxPerSec: 42));
      expect(c.activePreset, isNull);
    });

    test('notifies on state changes', () {
      final c = MotionTuningController();
      var notifications = 0;
      c.addListener((_) => notifications++);
      final baseline = notifications;

      c.usePreset(MotionTuningPreset.snappy);
      c.usePreset(MotionTuningPreset.cinematic);
      expect(notifications - baseline, 2);
    });
  });
}
