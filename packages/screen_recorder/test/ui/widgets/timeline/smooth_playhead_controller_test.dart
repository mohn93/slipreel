import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';

void main() {
  group('SmoothPlayheadController.rebaseBaseOnSpeedChange', () {
    // The boundary-jump audit (2026-06-03) tracked a visible "jump
    // then slow back" at slice seams to a stale `_basePosition` not
    // being rebased when `value.playbackSpeed` changed. A naive fix
    // rebased to `videoController.value.position` — but that lags by
    // up to one tick (~125–250ms), so the playhead snapped BACKWARD
    // by that much at the seam (a new jitter pattern). The contract
    // is: on rate change, rebase the extrapolator's anchor to the
    // current SMOOTHED position so only the slope changes, not the
    // y-intercept.
    test('returns the smoothed value as the new base (not v.position)', () {
      const smoothed = Duration(milliseconds: 5234);
      expect(
        SmoothPlayheadController.rebaseBaseOnSpeedChange(
          currentSmoothed: smoothed,
        ),
        smoothed,
      );
    });

    test('identity at zero (initial state)', () {
      expect(
        SmoothPlayheadController.rebaseBaseOnSpeedChange(
          currentSmoothed: Duration.zero,
        ),
        Duration.zero,
      );
    });

    test('preserves sub-millisecond precision', () {
      // Smoothed extrapolation uses microsecond-accurate math; rebasing
      // must not silently quantise to milliseconds.
      const smoothed = Duration(microseconds: 5234567);
      expect(
        SmoothPlayheadController.rebaseBaseOnSpeedChange(
          currentSmoothed: smoothed,
        ),
        smoothed,
      );
    });
  });

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
