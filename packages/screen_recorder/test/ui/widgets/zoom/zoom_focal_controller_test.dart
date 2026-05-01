import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

ZoomRegion _zoomAt({
  required Duration startTime,
  required Duration duration,
  Rect rect = const Rect.fromLTWH(100, 100, 200, 200),
  double zoomLevel = 2.0,
}) {
  return ZoomRegion(
    rect: rect,
    startTime: startTime,
    duration: duration,
    zoomLevel: zoomLevel,
    enterDuration: Duration.zero,
    exitDuration: Duration.zero,
  );
}

CursorRecording _recordingAt(List<({int micros, double x, double y})> samples) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(CursorPosition(
        x: s.x, y: s.y, timestampMicros: s.micros));
  }
  return r;
}

void main() {
  group('ZoomFocalController', () {
    test('returns null when no zoom is active', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: const Duration(seconds: 1),
        duration: const Duration(seconds: 1),
      );

      final update = ctrl.update(
        position: const Duration(milliseconds: 500),
        zoomRegions: [zoom],
        cursorRecording: _recordingAt([]),
      );

      expect(update, isNull);
      expect(ctrl.smoothedFocal, isNull);
    });

    test('snaps to cursor position on the first frame of a zoom', () {
      // Cursor at (500, 400) when zoom becomes active. Even with the
      // 0.18 lerp factor, the very first call must NOT lerp from null
      // (or from the rect.center) — the result has to be the raw
      // cursor target so the focal lands cleanly the moment the zoom
      // starts.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(0, 0, 100, 100), // center (50, 50)
      );
      final cursor = _recordingAt([
        (micros: 0, x: 500, y: 400),
      ]);

      final update = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
      );

      expect(update, isNotNull);
      expect(update!.zoom, same(zoom));
      expect(update.focal, const Offset(500, 400),
          reason: 'first frame of a zoom must snap, not lerp');
    });

    test('falls back to rect.center when no cursor sample exists', () {
      // Empty cursor track is the legacy / window-capture / pre-warmup
      // shape. Focal must fall back to the static rect center, not
      // throw or hold null.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(200, 100, 400, 300), // center (400, 250)
      );

      final update = ctrl.update(
        position: const Duration(milliseconds: 500),
        zoomRegions: [zoom],
        cursorRecording: _recordingAt([]),
      );

      expect(update, isNotNull);
      expect(update!.focal, const Offset(400, 250));
    });

    test('lerps toward target on subsequent frames within same zoom',
        () {
      // After the snap on frame 1, frame 2 should lerp from the snapped
      // value toward the new cursor target by exactly 0.18 (the default
      // smoothing factor that the playback screen has shipped with).
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
      );
      final cursor = _recordingAt([
        (micros: 0,        x: 100, y: 100),
        (micros: 1_000_000, x: 200, y: 200),
      ]);

      // Frame 1: snap to (100, 100).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
      );

      // Frame 2: cursor is now at (200, 200). Lerp from (100, 100) at
      // 0.18 → (118, 118).
      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
      );

      expect(update, isNotNull);
      expect(update!.focal.dx, closeTo(118, 1e-6));
      expect(update.focal.dy, closeTo(118, 1e-6));
    });

    test('honors a custom smoothing factor', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 0,   y: 0),
        (micros: 1_000_000, x: 100, y: 100),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
      );

      // Smoothing 0.5 → halfway between (0, 0) and (100, 100).
      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        smoothing: 0.5,
      );

      expect(update!.focal, const Offset(50, 50));
    });

    test(
        'snaps focal when crossing into a different zoom region '
        'instead of lerping across the screen', () {
      // Zoom A pinned to upper-left, zoom B pinned to lower-right with
      // no time gap between them. When playback crosses into B the
      // focal must snap to B's first-frame target — lerping from A's
      // last position would drag the camera diagonally across the
      // entire frame for several updates.
      final ctrl = ZoomFocalController();
      final zoomA = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(0, 0, 100, 100),
      );
      final zoomB = _zoomAt(
        startTime: const Duration(seconds: 1),
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(900, 800, 100, 100),
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 50,  y: 50),
        (micros: 1_500_000, x: 950, y: 850),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoomA, zoomB],
        cursorRecording: cursor,
      );

      final crossover = ctrl.update(
        position: const Duration(milliseconds: 1500),
        zoomRegions: [zoomA, zoomB],
        cursorRecording: cursor,
      );

      expect(crossover, isNotNull);
      expect(crossover!.zoom, same(zoomB));
      expect(crossover.focal, const Offset(950, 850),
          reason:
              'crossing into a new zoom region must snap, not lerp '
              'from the previous zoom\'s focal');
    });

    test(
        'clears smoothing state when leaving a zoom so the next entry '
        'snaps cleanly', () {
      // Same zoom region used twice (once in the middle of the
      // timeline, then again later). A gap with no zoom between them
      // must reset state — re-entering must snap to the new target,
      // not lerp from the leftover focal.
      final ctrl = ZoomFocalController();
      final zoomEarly = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(0, 0, 100, 100),
      );
      final zoomLate = _zoomAt(
        startTime: const Duration(seconds: 3),
        duration: const Duration(seconds: 1),
        rect: const Rect.fromLTWH(800, 800, 100, 100),
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 50,  y: 50),
        (micros: 3_500_000, x: 850, y: 850),
      ]);

      // Inside the early zoom.
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
      );

      // Gap (no zoom active) — should clear state.
      final mid = ctrl.update(
        position: const Duration(milliseconds: 2000),
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
      );
      expect(mid, isNull);
      expect(ctrl.smoothedFocal, isNull);

      // Re-enter with the late zoom — must snap to its target.
      final reEntry = ctrl.update(
        position: const Duration(milliseconds: 3500),
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
      );
      expect(reEntry!.focal, const Offset(850, 850));
    });

    test('reset() drops state so the next call snaps', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 100, y: 100),
        (micros: 1_000_000, x: 200, y: 200),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
      );
      expect(ctrl.smoothedFocal, const Offset(100, 100));

      ctrl.reset();
      expect(ctrl.smoothedFocal, isNull);

      // Next call should snap to the new target rather than lerp from
      // the previous (now-cleared) focal.
      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
      );
      expect(update!.focal, const Offset(200, 200));
    });

    test('exposes the current smoothed focal for debug HUDs', () {
      // The HUD reads ZoomFocalController.smoothedFocal between
      // update() calls to draw the yellow ring. Verify the getter
      // matches the last update's focal.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
      );
      final cursor = _recordingAt([
        (micros: 0, x: 700, y: 600),
      ]);

      final update = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
      );

      expect(ctrl.smoothedFocal, update!.focal);
    });
  });
}
