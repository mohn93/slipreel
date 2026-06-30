import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

const _video = Size(1920, 1080);

// Mirror of the helper's per-axis viewport-relative allowed-distance formula.
double _allowed(double viewportDim, double marginFrac) =>
    math.max(0.0, viewportDim * (0.5 - marginFrac));

void main() {
  final fr = ZoomFraming.identity(_video);

  test('cursor already centered: focal unchanged (no-op)', () {
    const focal = Offset(960, 540);
    final out = fr.clampFocalKeepCursorInView(focal, focal, 2.0, 0.05);
    expect((out - focal).distance, lessThan(0.001));
  });

  test('cursor well inside the safe area: focal unchanged', () {
    const focal = Offset(960, 540);
    final cursor = focal + const Offset(100, 0);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.05);
    expect((out - focal).distance, lessThan(0.001));
  });

  test('cursor beyond the safe area: focal pulled so the cursor sits at the '
      'safe-area edge', () {
    const z = 2.0;
    const margin = 0.05;
    const focal = Offset(960, 540);
    final allowedX = _allowed(_video.width / z, margin);
    final cursor = focal + Offset(allowedX + 200, 0); // well beyond, reachable
    final out = fr.clampFocalKeepCursorInView(focal, cursor, z, margin);
    expect(out.dx, closeTo(cursor.dx - allowedX, 0.5));
    expect(out.dy, closeTo(540, 0.5));
    expect((cursor.dx - out.dx).abs(), closeTo(allowedX, 0.5));
  });

  test('per-axis: only the breached axis is pulled; the in-view axis keeps its '
      'raw (unclamped) value', () {
    const z = 2.0;
    const margin = 0.05;
    // Focal Y is OUTSIDE the reachable range (270..810 at z=2) but the cursor
    // is in view on Y, so Y must come back verbatim (NOT reachable-clamped).
    const focal = Offset(960, 100);
    final allowedX = _allowed(_video.width / z, margin);
    final cursor = Offset(focal.dx + allowedX + 300, 100); // breach X only
    final out = fr.clampFocalKeepCursorInView(focal, cursor, z, margin);
    expect(out.dy, closeTo(100, 0.001), reason: 'in-view Y axis untouched');
    expect(out.dx, greaterThan(focal.dx), reason: 'X pulled toward cursor');
  });

  test('off-center in-view focal returned unchanged (not reachable-clamped)',
      () {
    // Focal (200,200) is outside the reachable range at z=2 but the cursor is
    // at the same point => in view => no pull => verbatim focal.
    const focal = Offset(200, 200);
    final out = fr.clampFocalKeepCursorInView(focal, focal, 2.0, 0.05);
    expect(out.dx, closeTo(200, 0.001));
    expect(out.dy, closeTo(200, 0.001));
  });

  test('near the true canvas edge: reachable clamp wins on the pulled axis',
      () {
    const focal = Offset(960, 540);
    const cursor = Offset(1915, 540); // hard against the right edge
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.05);
    // Reachable focal max at z=2 is 1920 - 1920/(2*2) = 1440; pull cannot exceed it.
    expect(out.dx, closeTo(1440, 0.5));
  });

  test('z <= 1: returns clampFocal unchanged', () {
    const focal = Offset(960, 540);
    const cursor = Offset(100, 100);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 1.0, 0.05);
    expect(out, fr.clampFocal(focal, 1.0));
  });
}
