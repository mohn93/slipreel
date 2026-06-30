import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

const _video = Size(1920, 1080);

void main() {
  final fr = ZoomFraming.identity(_video);

  test('cursor already centered: focal unchanged (no-op)', () {
    const focal = Offset(960, 540);
    final out = fr.clampFocalKeepCursorInView(focal, focal, 2.0, 0.1);
    expect((out - focal).distance, lessThan(0.001));
  });

  test('cursor well inside margin: focal unchanged', () {
    // z=2 viewport is 960x540, half = 480x270. margin = 0.1*1080 = 108.
    // allowed = 480-108 = 372 (x). Cursor 100px from focal is inside.
    const focal = Offset(960, 540);
    final cursor = focal + const Offset(100, 0);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.1);
    expect((out - focal).distance, lessThan(0.001));
  });

  test('cursor beyond margin: focal pulled minimally toward cursor', () {
    // allowedX = 372. Cursor 500px right of focal => focal must move so
    // it is within 372px of the cursor: focal.x = cursor.x - 372.
    const focal = Offset(960, 540);
    final cursor = focal + const Offset(500, 0);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.1);
    expect(out.dx, closeTo(cursor.dx - 372, 0.5));
    expect(out.dy, closeTo(540, 0.5));
    // Cursor is now exactly at the margin edge inside the viewport.
    expect((cursor.dx - out.dx).abs(), closeTo(372, 0.5));
  });

  test('near the true canvas edge: reachable clamp wins (degrades)', () {
    // Cursor hard against the right edge; keep-in-view wants focal further
    // right than reachable, so clampFocal pins the viewport on-canvas.
    const focal = Offset(960, 540);
    const cursor = Offset(1915, 540);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.1);
    // Reachable focal max at z=2 is 1920 - 1920/(2*2) = 1440.
    expect(out.dx, closeTo(1440, 0.5));
  });

  test('z <= 1: returns clampFocal unchanged', () {
    const focal = Offset(960, 540);
    const cursor = Offset(100, 100);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 1.0, 0.1);
    expect(out, fr.clampFocal(focal, 1.0));
  });
}
