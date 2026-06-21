@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level regression pin for the preview zoom scale↔pan desync.
///
/// The rendered zoom SCALE used to be gated by a badge `TweenAnimationBuilder`
/// that animated on Flutter's WALL clock. When playback crossed into an
/// adjacent zoom region with a different level, that tween lagged (e.g. 2→5) on
/// wall-time while the focal PAN ramped on SOURCE (video) time — so the pan
/// outran the scale during the enter ramp. The fix drives the level from a
/// snap-on-region-change `AnimationController` via `_displayedBadgeZoom`, so the
/// scale shares the source-time clock with the pan.
///
/// A widget-pump test can't reliably reproduce that dual-clock divergence
/// ("synthetic traces come out clean"), so this pins the structure instead:
/// the wall-clock tween must not be reintroduced around the zoom transform, and
/// the scale must keep flowing from the controller-resolved level.
void main() {
  final src = File(
    'lib/ui/widgets/zoom/playback_canvas.dart',
  ).readAsStringSync();

  // Strip full-line `//` comments so prose that mentions the old widget name
  // doesn't trip the check — we only care about real code.
  final code = src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('the zoom transform is not gated by a wall-clock TweenAnimationBuilder', () {
    expect(
      code.contains('TweenAnimationBuilder'),
      isFalse,
      reason:
          'A TweenAnimationBuilder around getTransform animates the rendered '
          'scale on Flutter\'s wall clock, so it lags the source-time pan ramp '
          'on region crossings (the scale↔pan desync). Drive the level from '
          '_displayedBadgeZoom / _badgeController instead.',
    );
  });

  test('the active region snaps the badge level and feeds it to getTransform', () {
    // Snap on region-identity change keeps the scale lock-step with the pan.
    expect(
      code.contains('_syncBadgeRegion(activeZoom)'),
      isTrue,
      reason: 'build must snap the badge level when the active region changes.',
    );
    // The scale fed to the transform comes from the controller-resolved level.
    expect(
      code.contains('_displayedBadgeZoom'),
      isTrue,
      reason: 'the rendered scale level must come from _displayedBadgeZoom.',
    );
    expect(
      code.contains('zoomLevel: displayedZoom'),
      isTrue,
      reason: 'getTransform must receive the controller-resolved displayedZoom.',
    );
  });
}
