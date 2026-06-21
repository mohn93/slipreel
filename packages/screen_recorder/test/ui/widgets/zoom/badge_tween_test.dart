@TestOn('vm')
library;

import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';

/// Unit pins for the preview badge zoom-LEVEL tween decision.
///
/// The rendered zoom SCALE is gated by an animated "displayed" level. The bug:
/// when playback crosses into an adjacent zoom region with a DIFFERENT level,
/// the old `TweenAnimationBuilder` animated that level on Flutter's WALL clock,
/// so the scale lagged the focal PAN (which ramps on SOURCE/video time) — the
/// pan outran the scale. The fix SNAPS the displayed level to the new region's
/// real level on a region-identity change (lock-step with the source-time pan)
/// and only ANIMATES on a same-region level edit (inspector smoothing).
///
/// These tests are clock-INDEPENDENT (pure comparisons), so they sidestep the
/// "synthetic timing traces come out clean" problem that makes the full
/// dual-clock divergence unreliable to reproduce in a widget pump.
void main() {
  const k1 = Duration(microseconds: 3362069);
  const k2 = Duration(microseconds: 5362069);

  group('badgeTweenDecision', () {
    test('region identity change snaps to the new region real level', () {
      final d = badgeTweenDecision(
        prevKey: k1,
        prevLevel: 2.0,
        currentDisplayed: 2.0,
        activeKey: k2,
        activeLevel: 5.0,
      );
      expect(d.action, BadgeTweenAction.snap);
      // begin == end == real level: the rendered scale uses the new level
      // immediately, regardless of any controller value -> lock-step with pan.
      expect(d.begin, 5.0);
      expect(d.end, 5.0);
      expect(d.level, 5.0);
      expect(d.key, k2);
    });

    test('first active region (no prior key) snaps', () {
      final d = badgeTweenDecision(
        prevKey: null,
        prevLevel: 1.0,
        currentDisplayed: 1.0,
        activeKey: k1,
        activeLevel: 2.0,
      );
      expect(d.action, BadgeTweenAction.snap);
      expect(d.begin, 2.0);
      expect(d.end, 2.0);
    });

    test('same region with an edited level animates from the current displayed '
        'value to the new level', () {
      final d = badgeTweenDecision(
        prevKey: k2,
        prevLevel: 5.0,
        currentDisplayed: 4.2,
        activeKey: k2,
        activeLevel: 3.0,
      );
      expect(d.action, BadgeTweenAction.animate);
      expect(d.begin, 4.2); // re-anchor at the current displayed value
      expect(d.end, 3.0); // animate toward the new level
      expect(d.level, 3.0);
    });

    test('same region and unchanged level holds', () {
      final d = badgeTweenDecision(
        prevKey: k2,
        prevLevel: 5.0,
        currentDisplayed: 5.0,
        activeKey: k2,
        activeLevel: 5.0,
      );
      expect(d.action, BadgeTweenAction.hold);
    });
  });

  group('badgeDisplayedLevel', () {
    test('a snapped decision renders the real level at EVERY tween progress '
        '(scale never wall-clock gated on a crossing)', () {
      final d = badgeTweenDecision(
        prevKey: k1,
        prevLevel: 2.0,
        currentDisplayed: 2.0,
        activeKey: k2,
        activeLevel: 5.0,
      );
      for (final t in <double>[0.0, 0.25, 0.5, 0.9, 1.0]) {
        expect(
          badgeDisplayedLevel(d.begin, d.end, Curves.easeInOutCubic, t),
          5.0,
          reason: 'snapped scale must equal the real level at t=$t',
        );
      }
    });

    test('an animating decision interpolates begin -> end across progress', () {
      final d = badgeTweenDecision(
        prevKey: k2,
        prevLevel: 2.0,
        currentDisplayed: 2.0,
        activeKey: k2,
        activeLevel: 5.0,
      );
      expect(badgeDisplayedLevel(d.begin, d.end, Curves.linear, 0.0), 2.0);
      expect(badgeDisplayedLevel(d.begin, d.end, Curves.linear, 1.0), 5.0);
      expect(badgeDisplayedLevel(d.begin, d.end, Curves.linear, 0.5), 3.5);
    });
  });
}
