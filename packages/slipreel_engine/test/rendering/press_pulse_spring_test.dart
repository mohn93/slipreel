import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';

void main() {
  group('pressPulseMultiplier (spring)', () {
    test('no click yet returns 1.0', () {
      expect(
        pressPulseMultiplier(
          microsSinceClick: null,
          microsSinceRelease: null,
        ),
        closeTo(1.0, 1e-9),
      );
    });

    test('press start (t≈0): cursor is essentially full size', () {
      final m = pressPulseMultiplier(
        microsSinceClick: 0,
        microsSinceRelease: null,
      );
      expect(m, closeTo(1.0, 1e-6));
    });

    test('press long-hold: cursor settles near the held multiplier (~0.86)',
        () {
      // Snappy preset at t = 600 ms after press, no release: the
      // spring has had plenty of time to settle on its target
      // (_heldMultiplier = 0.86 internally).
      final m = pressPulseMultiplier(
        microsSinceClick: 600000,
        microsSinceRelease: null,
      );
      expect(m, closeTo(0.86, 0.02),
          reason: 'A critically-damped spring should be within ~2% of the '
              'held target after a few settling-time periods.');
    });

    test('release long-after: cursor settles back at 1.0', () {
      // Press fully completed (hold > 500 ms) and release fully
      // completed (release > 500 ms). Spring is at rest at 1.0.
      // microsSinceClick is the TOTAL time since press-down — must
      // be larger than microsSinceRelease for the controller to
      // recognise this as a released state.
      final m = pressPulseMultiplier(
        microsSinceClick: 1500000,
        microsSinceRelease: 800000,
      );
      expect(m, closeTo(1.0, 0.02));
    });

    test('still-held heuristic: microsSinceRelease > microsSinceClick means '
        'the most recent event was the press, not a release', () {
      // Releases that happened *before* the current press are
      // irrelevant — we should still see the press-in chase.
      final m = pressPulseMultiplier(
        microsSinceClick: 50000,
        microsSinceRelease: 1000000,
      );
      // At 50 ms into the press the cursor has dipped from 1.0 but
      // hasn't settled yet. Bounded by the two endpoints.
      expect(m, lessThan(1.0));
      expect(m, greaterThan(0.86));
    });

    test('release-out is monotonically heading back toward 1.0 (snappy spring)',
        () {
      // Critically damped: no overshoot. Sampled at two points in
      // the release phase, the later one should be closer to 1.0.
      // microsSinceClick = microsSinceRelease + hold; pick a long
      // hold so the press has fully settled to _heldMultiplier
      // first.
      const longHold = 600000;
      final early = pressPulseMultiplier(
        microsSinceClick: longHold + 40000,
        microsSinceRelease: 40000,
      );
      final later = pressPulseMultiplier(
        microsSinceClick: longHold + 150000,
        microsSinceRelease: 150000,
      );
      expect(later, greaterThan(early),
          reason: 'Snappy (critical) release should monotonically chase '
              '1.0 — overshoot is only present at low damping.');
      expect(early, greaterThan(0.86 - 1e-6));
      expect(later, lessThan(1.0 + 1e-6));
    });

    test('bouncy click spring overshoots 1.0 during release', () {
      // Drop the damping ratio so the spring rings. After release
      // there should be a sample where the size briefly exceeds
      // 1.0. This is the visible "bounce" the user buys when they
      // dial damping below 1.0.
      const bouncy = ClickSpring(stiffness: 350, damping: 0.4);
      const longHold = 600000;

      // Sweep the first ~120 ms of release in 5 ms steps and check
      // the peak.
      double peak = 0.0;
      for (var t = 0; t <= 120000; t += 5000) {
        final m = pressPulseMultiplier(
          microsSinceClick: longHold + t,
          microsSinceRelease: t,
          spring: bouncy,
        );
        if (m > peak) peak = m;
      }
      expect(peak, greaterThan(1.0),
          reason: 'A damping ratio < 1.0 must produce a visible overshoot '
              'past 1.0 during the release-out chase.');
    });

    test('stiffer click spring settles faster on press', () {
      // Compare two springs sampled at the same press time. The
      // stiffer one is further along the press chase (closer to
      // _heldMultiplier).
      const soft = ClickSpring(stiffness: 150, damping: 1.0);
      const stiff = ClickSpring(stiffness: 800, damping: 1.0);
      final softM = pressPulseMultiplier(
        microsSinceClick: 60000,
        microsSinceRelease: null,
        spring: soft,
      );
      final stiffM = pressPulseMultiplier(
        microsSinceClick: 60000,
        microsSinceRelease: null,
        spring: stiff,
      );
      // Both are travelling from 1.0 down to 0.86. Stiffer = farther
      // along = smaller multiplier.
      expect(stiffM, lessThan(softM));
    });
  });
}
