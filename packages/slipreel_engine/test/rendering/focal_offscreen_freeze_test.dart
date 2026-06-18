import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';

const Size _videoSize = Size(1000, 600);

ZoomRegion _region() => ZoomRegion(
      rect: const Rect.fromLTRB(0, 0, 0, 0),
      startTime: Duration.zero,
      duration: const Duration(seconds: 20),
      zoomLevel: 2.0,
      enterDuration: Duration.zero,
      exitDuration: Duration.zero,
      followCursor: true,
      followMode: FollowMode.centered,
      deadzoneRatio: 0.3,
      followDuration: const Duration(milliseconds: 400),
    );

ZoomFocalUpdate? _drive(
  ZoomFocalController ctrl,
  ZoomRegion zoom, {
  required Duration from,
  required Duration to,
  required Offset cursor,
}) {
  ZoomFocalUpdate? last;
  const step = Duration(milliseconds: 16);
  var t = from;
  while (t <= to) {
    last = ctrl.update(
      position: t,
      zoomRegions: [zoom],
      cursor: cursor,
      videoSize: _videoSize,
    );
    t += step;
  }
  return last;
}

void main() {
  // Multi-monitor recordings move the cursor onto another display, recorded
  // as out-of-video-bounds coordinates. The follow camera must NOT chase the
  // cursor off-screen — it should FREEZE the focal at the last on-screen
  // position until the cursor returns.
  test('cursor leaving the frame freezes the focal at its last in-bounds spot',
      () {
    final ctrl = ZoomFocalController();
    final zoom = _region();

    // Settle the follow on an in-bounds, left-of-center cursor.
    _drive(ctrl, zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 1600),
        cursor: const Offset(300, 300));
    final settled = ctrl.smoothedFocal!;
    expect(settled.dx, closeTo(300, 25),
        reason: 'spring should have settled on the in-bounds cursor');

    // Cursor jumps far off-screen (another monitor, negative coords).
    final after = _drive(ctrl, zoom,
        from: const Duration(milliseconds: 1616),
        to: const Duration(milliseconds: 2600),
        cursor: const Offset(-400, -400))!;

    // It must stay parked near (300,300), NOT drift toward (-400,-400).
    expect(after.focal.dx, greaterThan(270),
        reason: 'focal must not chase the off-screen cursor leftward');
    expect(after.focal.dy, greaterThan(270),
        reason: 'focal must not chase the off-screen cursor upward');
  });

  test('cursor returning on-screen resumes following', () {
    final ctrl = ZoomFocalController();
    final zoom = _region();

    _drive(ctrl, zoom,
        from: Duration.zero,
        to: const Duration(milliseconds: 1200),
        cursor: const Offset(300, 300));
    _drive(ctrl, zoom,
        from: const Duration(milliseconds: 1216),
        to: const Duration(milliseconds: 1800),
        cursor: const Offset(-400, -400));

    // Cursor comes back on-screen on the right.
    final back = _drive(ctrl, zoom,
        from: const Duration(milliseconds: 1816),
        to: const Duration(milliseconds: 3200),
        cursor: const Offset(720, 320))!;

    expect(back.focal.dx, closeTo(720, 40),
        reason: 'follow should resume once the cursor is back in bounds');
  });
}
