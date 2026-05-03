import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/ui/widgets/zoom/cursor_motion_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _recordingAt(
    List<({int micros, double x, double y, bool clicked})> samples) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(CursorPosition(
      x: s.x,
      y: s.y,
      timestampMicros: s.micros,
      isClicked: s.clicked,
    ));
  }
  return r;
}

void main() {
  group('CursorMotionController', () {
    test('returns null when there is no cursor data', () {
      final ctrl = CursorMotionController();
      final out = ctrl.update(
        position: const Duration(milliseconds: 50),
        cursorRecording: _recordingAt([]),
      );
      expect(out, isNull);
    });

    test('snaps to the recorded position on the first frame', () {
      final ctrl = CursorMotionController();
      final rec = _recordingAt([
        (micros: 0, x: 100, y: 200, clicked: false),
      ]);

      final out = ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        smoothing: 0.08,
      );

      expect(out!.screenPos, const Offset(100, 200));
    });

    test('lerps toward target on subsequent frames within threshold', () {
      final ctrl = CursorMotionController();
      final rec = _recordingAt([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16000, x: 100, y: 0, clicked: false),
      ]);

      ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        smoothing: 0.5,
      );
      final out = ctrl.update(
        position: const Duration(milliseconds: 16),
        cursorRecording: rec,
        smoothing: 0.5,
      );

      // Lerp from (0,0) toward (100,0) at 0.5 → (50, 0).
      expect(out!.screenPos.dx, closeTo(50, 1e-9));
      expect(out.screenPos.dy, closeTo(0, 1e-9));
    });

    test('snaps when the playhead jumps past the scrub threshold', () {
      // Without snapping, scrubbing the playhead would lerp the cursor
      // slowly across the whole video at the smoothing rate. We snap
      // when consecutive update() calls are >100 ms apart.
      final ctrl = CursorMotionController();
      final rec = _recordingAt([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 5000000, x: 800, y: 600, clicked: false),
      ]);

      ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        smoothing: 0.08,
      );

      final out = ctrl.update(
        position: const Duration(seconds: 5),
        cursorRecording: rec,
        smoothing: 0.08,
      );

      expect(out!.screenPos, const Offset(800, 600));
    });

    test('smoothing >= 1.0 means no lerp (matches old direct render)',
        () {
      final ctrl = CursorMotionController();
      final rec = _recordingAt([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16000, x: 200, y: 0, clicked: false),
      ]);

      ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        smoothing: 1.0,
      );
      final out = ctrl.update(
        position: const Duration(milliseconds: 16),
        cursorRecording: rec,
        smoothing: 1.0,
      );

      expect(out!.screenPos, const Offset(200, 0));
    });

    test('repeated update() at the same position is idempotent', () {
      // A parent setState (e.g. inspector toggle) can trigger an extra
      // builder run for the same playhead. Like ZoomFocalController,
      // we cache by position so smoothing doesn't advance twice.
      final ctrl = CursorMotionController();
      final rec = _recordingAt([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16000, x: 100, y: 0, clicked: false),
      ]);

      ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        smoothing: 0.5,
      );

      final firstAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        cursorRecording: rec,
        smoothing: 0.5,
      );
      final secondAtT2 = ctrl.update(
        position: const Duration(milliseconds: 16),
        cursorRecording: rec,
        smoothing: 0.5,
      );

      expect(secondAtT2!.screenPos, firstAtT2!.screenPos);
    });

    test('reset() drops state so the next call snaps', () {
      final ctrl = CursorMotionController();
      final rec = _recordingAt([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16000, x: 100, y: 0, clicked: false),
      ]);

      ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        smoothing: 0.5,
      );
      ctrl.reset();
      final out = ctrl.update(
        position: const Duration(milliseconds: 16),
        cursorRecording: rec,
        smoothing: 0.5,
      );

      // After reset the next call should snap, not lerp from the
      // previous state.
      expect(out!.screenPos, const Offset(100, 0));
    });
  });
}
