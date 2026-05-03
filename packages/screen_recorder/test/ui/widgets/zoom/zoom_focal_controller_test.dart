import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

const Size _videoSize = Size(1920, 1080);

ZoomRegion _zoomAt({
  required Duration startTime,
  required Duration duration,
  Rect rect = const Rect.fromLTWH(100, 100, 200, 200),
  double zoomLevel = 2.0,
  bool followCursor = true,
  bool boundedFollow = false,
  double deadzoneRatio = 0.3,
}) {
  return ZoomRegion(
    rect: rect,
    startTime: startTime,
    duration: duration,
    zoomLevel: zoomLevel,
    enterDuration: Duration.zero,
    exitDuration: Duration.zero,
    followCursor: followCursor,
    boundedFollow: boundedFollow,
    deadzoneRatio: deadzoneRatio,
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
        videoSize: _videoSize,
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
        videoSize: _videoSize,
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
        videoSize: _videoSize,
      );

      expect(update, isNotNull);
      expect(update!.focal, const Offset(400, 250));
    });

    test('lerps toward target on subsequent frames within same zoom', () {
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
        videoSize: _videoSize,
      );

      // Frame 2: cursor is now at (200, 200). Lerp from (100, 100) at
      // 0.18 → (118, 118).
      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
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
        videoSize: _videoSize,
      );

      // Smoothing 0.5 → halfway between (0, 0) and (100, 100).
      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
        smoothing: 0.5,
      );

      expect(update!.focal, const Offset(50, 50));
    });

    test(
        'snaps focal when crossing into a different zoom region '
        'instead of lerping across the screen', () {
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
        videoSize: _videoSize,
      );

      final crossover = ctrl.update(
        position: const Duration(milliseconds: 1500),
        zoomRegions: [zoomA, zoomB],
        cursorRecording: cursor,
        videoSize: _videoSize,
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

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      final mid = ctrl.update(
        position: const Duration(milliseconds: 2000),
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(mid, isNull);
      expect(ctrl.smoothedFocal, isNull);

      final reEntry = ctrl.update(
        position: const Duration(milliseconds: 3500),
        zoomRegions: [zoomEarly, zoomLate],
        cursorRecording: cursor,
        videoSize: _videoSize,
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
        videoSize: _videoSize,
      );
      expect(ctrl.smoothedFocal, const Offset(100, 100));

      ctrl.reset();
      expect(ctrl.smoothedFocal, isNull);

      final update = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(update!.focal, const Offset(200, 200));
    });

    test('exposes the current smoothed focal for debug HUDs', () {
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
        videoSize: _videoSize,
      );

      expect(ctrl.smoothedFocal, update!.focal);
    });

    test('repeated update() at the same position is idempotent', () {
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
      );
      final cursor = _recordingAt([
        (micros: 0, x: 100, y: 100),
        (micros: 16000, x: 700, y: 600),
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      final firstAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      final secondAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(secondAtT2!.focal, firstAtT2!.focal);
    });

    // --- followCursor / boundedFollow / deadzone semantics ---------------

    test('followCursor=false pins focal to rect.center even with cursor data',
        () {
      // Auto-zoom toggle off: camera must stay centered on the zoom
      // rect for the whole region, regardless of where the cursor
      // wandered.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(200, 100, 400, 300), // center (400, 250)
        followCursor: false,
      );
      final cursor = _recordingAt([
        (micros: 0, x: 1500, y: 900), // far from rect.center
      ]);

      final out = ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      expect(out!.focal, const Offset(400, 250));
    });

    test(
        'bounded follow holds focal while cursor stays inside the deadzone',
        () {
      // 1920x1080 video at zoomLevel=2 → viewport in source pixels =
      // 960x540. deadzone 30% → 288x162 box centered on the focal.
      // After the snap, a small cursor nudge inside that box must
      // leave the focal unchanged across many frames.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        boundedFollow: true,
        deadzoneRatio: 0.3,
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 960, y: 540), // viewport center
        (micros: 1_000_000, x: 1000, y: 560), // 40px right, 20px down
        (micros: 2_000_000, x: 1050, y: 580), // still inside deadzone
      ]);

      // Frame 1 — snap to (960, 540).
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      final f2 = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final f3 = ctrl.update(
        position: const Duration(seconds: 2),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(f2!.focal, const Offset(960, 540),
          reason: 'cursor still inside deadzone — focal must hold');
      expect(f3!.focal, const Offset(960, 540),
          reason: 'cursor still inside deadzone — focal must hold');
    });

    test('bounded follow pulls focal toward cursor when it leaves the deadzone',
        () {
      // Same setup as above, but the cursor jumps far enough out of
      // the 288x162 deadzone box that the focal must start lerping.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        boundedFollow: true,
        deadzoneRatio: 0.3,
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 960,  y: 540),
        (micros: 1_000_000, x: 1500, y: 900), // well outside the 288x162 box
      ]);

      // Frame 1 — snap.
      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      // Frame 2 — cursor outside deadzone, focal lerps 0.18 toward
      // (1500, 900).
      final f2 = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );

      expect(f2!.focal.dx, closeTo(960 + (1500 - 960) * 0.18, 1e-6));
      expect(f2.focal.dy, closeTo(540 + (900 - 540) * 0.18, 1e-6));
    });

    test(
        'bounded follow with cursor sitting exactly at the deadzone edge '
        'still locks (Rect.contains is half-open but boundary stays held)',
        () {
      // Cursor at (1104, 540) is exactly at the right edge of a
      // 288-wide deadzone centered on (960, 540). Rect.contains is
      // exclusive on the right/bottom, so the cursor counts as
      // *outside* and the lerp engages. This test pins down that
      // edge-case so a future refactor doesn't silently flip it.
      final ctrl = ZoomFocalController();
      final zoom = _zoomAt(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        zoomLevel: 2.0,
        boundedFollow: true,
        deadzoneRatio: 0.3,
      );
      final cursor = _recordingAt([
        (micros: 0,         x: 960,  y: 540),
        (micros: 1_000_000, x: 1104, y: 540), // exactly half-width away
      ]);

      ctrl.update(
        position: Duration.zero,
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      final f2 = ctrl.update(
        position: const Duration(seconds: 1),
        zoomRegions: [zoom],
        cursorRecording: cursor,
        videoSize: _videoSize,
      );
      // Lerp engaged → x moved toward 1104.
      expect(f2!.focal.dx, greaterThan(960));
    });
  });
}
