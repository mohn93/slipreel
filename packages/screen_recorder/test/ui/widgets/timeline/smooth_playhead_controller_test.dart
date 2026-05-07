import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';

void main() {
  group('SmoothPlayheadController.resolvePausedPosition', () {
    const duration = Duration(seconds: 10);

    test('returns position as-is when far from duration', () {
      // User pauses mid-clip — leave the playhead exactly where it is.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          const Duration(seconds: 5),
          duration,
        ),
        const Duration(seconds: 5),
      );
    });

    test('pins to duration when within end-of-clip tolerance (33ms)', () {
      // Typical 30fps last-frame timestamp is duration - 1/30s = -33ms.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration - const Duration(milliseconds: 33),
          duration,
        ),
        duration,
      );
    });

    test('pins to duration when within tolerance (16ms / 60fps)', () {
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration - const Duration(milliseconds: 16),
          duration,
        ),
        duration,
      );
    });

    test('does NOT pin when 100ms or more below duration', () {
      // Boundary: tolerance is "less than 100ms". 100ms exactly is
      // NOT pinned — caller likely paused intentionally.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration - const Duration(milliseconds: 100),
          duration,
        ),
        duration - const Duration(milliseconds: 100),
      );
    });

    test('clamps positions past duration to duration', () {
      // Defensive: extrapolation overshoot should never report past
      // duration even if a buggy native layer surfaces it.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration + const Duration(milliseconds: 50),
          duration,
        ),
        duration,
      );
    });

    test('returns position as-is when duration is zero (uninitialized)', () {
      // Don't pin anything before the controller knows the clip length.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          const Duration(seconds: 1),
          Duration.zero,
        ),
        const Duration(seconds: 1),
      );
    });
  });
}
