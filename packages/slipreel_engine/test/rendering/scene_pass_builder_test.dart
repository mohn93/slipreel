import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

const Size _videoSize = Size(1920, 1080);

CursorRecording _record(
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

/// Cursor recording with the cursor on a straight east-bound line at
/// 600 px/s, sampled at 60 Hz, lasting [durationMs]. Coordinates start
/// at [start].
CursorRecording _eastBoundRecording({
  required int durationMs,
  double pxPerSec = 600,
  Offset start = const Offset(960, 540),
}) {
  const stepMs = 16;
  final out = <({int micros, double x, double y, bool clicked})>[];
  for (var t = 0; t <= durationMs; t += stepMs) {
    final dx = pxPerSec * t / 1000.0;
    out.add(
      (micros: t * 1000, x: start.dx + dx, y: start.dy, clicked: false),
    );
  }
  return _record(out);
}

EditorProjectState _projectWith({required List<ZoomRegion> zooms}) {
  return EditorProjectState.defaults().copyWith(zoomRegions: zooms);
}

ZoomRegion _bounded({
  required Duration startTime,
  required Duration duration,
  Rect rect = const Rect.fromLTRB(0, 0, 0, 0),
  double zoomLevel = 2.0,
  double deadzoneRatio = 0.4,
  Duration enterDuration = Duration.zero,
}) {
  return ZoomRegion(
    rect: rect,
    startTime: startTime,
    duration: duration,
    zoomLevel: zoomLevel,
    enterDuration: enterDuration,
    exitDuration: Duration.zero,
    followCursor: true,
    followMode: FollowMode.bounded,
    deadzoneRatio: deadzoneRatio,
    followDuration: const Duration(milliseconds: 400),
  );
}

ZoomRegion _predictive({
  required Duration startTime,
  required Duration duration,
  Rect rect = const Rect.fromLTRB(0, 0, 0, 0),
  Duration predictiveWindow = const Duration(milliseconds: 500),
}) {
  return ZoomRegion(
    rect: rect,
    startTime: startTime,
    duration: duration,
    zoomLevel: 2.0,
    enterDuration: Duration.zero,
    exitDuration: Duration.zero,
    followCursor: true,
    followMode: FollowMode.predictive,
    predictiveWindow: predictiveWindow,
    followDuration: const Duration(milliseconds: 400),
  );
}

/// Drive the builder forward at 16 ms steps from `from` to `to`, using
/// the same project + recording for every frame. Returns the final pass.
/// The builder is stateful, so most behaviour only emerges after the
/// spring has been primed and integrated for several frames.
ScenePass _drive(
  ScenePassBuilder builder, {
  required EditorProjectState project,
  required CursorRecording recording,
  required Duration from,
  required Duration to,
  Duration step = const Duration(milliseconds: 16),
  bool forceSnap = false,
}) {
  ScenePass? last;
  var t = from + step;
  while (t <= to) {
    last = builder.build(
      position: t,
      zoomRegions: project.zoomRegions,
      cursorAnimationConfig: project.cursorAnimationConfig,
      cursorDelay: project.cursorDelay,
      cursorPostProcess: project.cursorPostProcess,
      cursorRecording: recording,
      videoSize: _videoSize,
      fps: 60,
      hasCursorData: recording.count > 0,
      forceSnap: forceSnap,
    );
    t += step;
  }
  return last!;
}

void main() {
  group('ScenePassBuilder', () {
    test('returns no focal update when no zoom is active', () {
      final builder = ScenePassBuilder();
      final project = _projectWith(zooms: const []);

      final pass = builder.build(
        position: const Duration(milliseconds: 100),
        zoomRegions: project.zoomRegions,
        cursorAnimationConfig: project.cursorAnimationConfig,
        cursorRecording: CursorRecording(),
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: false,
      );

      expect(pass.focalUpdate, isNull);
      expect(pass.activeZoom, isNull);
      expect(pass.motion, isNull);
    });

    test('returns null motion when hasCursorData is false', () {
      final builder = ScenePassBuilder();
      // A zoom is active so the focal path runs, but cursor data is
      // unavailable (legacy / window-source recording).
      final project = _projectWith(
        zooms: [
          _bounded(
            startTime: Duration.zero,
            duration: const Duration(seconds: 1),
          ),
        ],
      );

      final pass = builder.build(
        position: const Duration(milliseconds: 100),
        zoomRegions: project.zoomRegions,
        cursorAnimationConfig: project.cursorAnimationConfig,
        cursorRecording: CursorRecording(),
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: false,
      );

      expect(pass.motion, isNull);
      expect(pass.cursorForFocal, isNull);
      // Focal still runs (camera parks at zoom rect centre).
      expect(pass.focalUpdate, isNotNull);
    });

    test(
      'propagates cursor velocity to the bounded gate '
      '(gate stays engaged while cursor moves through dz)',
      () {
        // BUG #2 in the architecture review: FrameCompositor was not
        // passing cursorVelocity to ZoomFocalController.update, so the
        // velocity-aware gate-release would fire mid-flight whenever the
        // cursor briefly entered the deadzone — producing a snap-back
        // followed by a chase. The unified builder MUST plumb the
        // motion sample's velocity through to the focal controller for
        // both call sites.
        //
        // Setup: a bounded zoom at 2× with a generous deadzone, cursor
        // moving east at 600 px/s (well above the 80 px/s "at-rest"
        // threshold) across the deadzone. The gate engages on entry
        // and must STAY engaged the entire time the cursor is moving.
        final builder = ScenePassBuilder();
        final project = _projectWith(
          zooms: [
            _bounded(
              startTime: Duration.zero,
              duration: const Duration(seconds: 2),
              rect: const Rect.fromLTWH(960, 540, 0, 0),
              deadzoneRatio: 0.6,
            ),
          ],
        );
        final recording = _eastBoundRecording(durationMs: 1000);

        // Drive 800 ms forward — long enough that the cursor has
        // travelled ~480 px east of the rect centre.
        final pass = _drive(
          builder,
          project: project,
          recording: recording,
          from: Duration.zero,
          to: const Duration(milliseconds: 800),
        );

        // The focal gate must read a non-zero cursor velocity (it came
        // from the motion sample). This is the direct contract being
        // tested.
        expect(pass.rawCursorVelocity.distance, greaterThan(200),
            reason:
                'Builder must compute cursor scene velocity from the recording');

        // And the gate must be engaged: cursor crossed the dz boundary
        // moving fast, gate did not flap to released mid-flight.
        expect(builder.focal.inFlight, isTrue,
            reason:
                'With cursorVelocity > 80 px/s, bounded gate must remain '
                'engaged across the deadzone instead of releasing each frame');
      },
    );

    test('uses median cursor for predictive follow mode', () {
      // Predictive mode points the focal at the dwell location (median
      // of recent samples), not the instantaneous cursor. With a
      // straight-line moving cursor the median lags behind the sprite,
      // so this is a visible, asserted divergence.
      final builder = ScenePassBuilder();
      final project = _projectWith(
        zooms: [
          _predictive(
            startTime: Duration.zero,
            duration: const Duration(seconds: 2),
            rect: const Rect.fromLTWH(960, 540, 0, 0),
            predictiveWindow: const Duration(milliseconds: 400),
          ),
        ],
      );
      final recording = _eastBoundRecording(durationMs: 1000);

      final pass = _drive(
        builder,
        project: project,
        recording: recording,
        from: Duration.zero,
        to: const Duration(milliseconds: 600),
      );

      expect(pass.activeZoom, isNotNull);
      expect(pass.activeZoom!.followMode, FollowMode.predictive);
      expect(pass.motion, isNotNull,
          reason: 'Motion sample still computed for the cursor sprite');
      // cursorForFocal != motion.screenPos in predictive mode.
      expect(pass.cursorForFocal, isNotNull);
      expect(
        (pass.cursorForFocal! - pass.motion!.screenPos).distance,
        greaterThan(10),
        reason:
            'Predictive cursor (median over window) lags the spring-smoothed '
            'sprite by at least a few pixels on a fast-moving cursor',
      );
    });

    test('uses motion sprite for bounded follow mode', () {
      final builder = ScenePassBuilder();
      final project = _projectWith(
        zooms: [
          _bounded(
            startTime: Duration.zero,
            duration: const Duration(seconds: 2),
            rect: const Rect.fromLTWH(960, 540, 0, 0),
          ),
        ],
      );
      final recording = _eastBoundRecording(durationMs: 800);

      final pass = _drive(
        builder,
        project: project,
        recording: recording,
        from: Duration.zero,
        to: const Duration(milliseconds: 400),
      );

      expect(pass.activeZoom!.followMode, FollowMode.bounded);
      expect(pass.cursorForFocal, equals(pass.motion!.screenPos),
          reason:
              'Non-predictive follow modes feed the motion sprite to the focal');
    });

    test('filteredCursorVelocity differs from raw when EMA is engaged', () {
      // After several frames of motion the EMA filter has built up
      // history; its output should NOT equal the raw scene velocity
      // (which jitters frame-to-frame).
      final builder = ScenePassBuilder();
      final project = _projectWith(
        zooms: [
          _bounded(
            startTime: Duration.zero,
            duration: const Duration(seconds: 2),
            rect: const Rect.fromLTWH(960, 540, 0, 0),
          ),
        ],
      );
      // Cursor that accelerates: x = 0.5 * a * t^2 → raw velocity ramps
      // each frame. EMA-filtered velocity lags the raw, so they diverge.
      const stepMs = 16;
      final samples = <({int micros, double x, double y, bool clicked})>[];
      for (var t = 0; t <= 500; t += stepMs) {
        final tSec = t / 1000.0;
        // 2400 px/s^2 → reaches 1200 px/s at 500 ms.
        final x = 960 + 0.5 * 2400 * tSec * tSec;
        samples.add((micros: t * 1000, x: x, y: 540, clicked: false));
      }
      final recording = _record(samples);

      final pass = _drive(
        builder,
        project: project,
        recording: recording,
        from: Duration.zero,
        to: const Duration(milliseconds: 480),
      );

      expect(pass.rawCursorVelocity.distance, greaterThan(500));
      // EMA lags the accelerating signal — measurable difference.
      expect(
        (pass.filteredCursorVelocity - pass.rawCursorVelocity).distance,
        greaterThan(10),
        reason: 'EMA filter must smooth the raw velocity by default',
      );
    });

    test('bypassVelocityFilter=true returns raw velocity as filtered', () {
      // Hover-scrub semantics: with bypass on, the filtered output
      // equals the raw input so timeline-scrubbing renders are
      // independent of which direction the user approached from.
      final builder = ScenePassBuilder();
      final project = _projectWith(
        zooms: [
          _bounded(
            startTime: Duration.zero,
            duration: const Duration(seconds: 2),
            rect: const Rect.fromLTWH(960, 540, 0, 0),
          ),
        ],
      );
      final recording = _eastBoundRecording(durationMs: 500);

      // Drive a few frames normally first so the EMA has state.
      _drive(
        builder,
        project: project,
        recording: recording,
        from: Duration.zero,
        to: const Duration(milliseconds: 200),
      );

      // Now call with bypass on.
      final pass = builder.build(
        position: const Duration(milliseconds: 216),
        zoomRegions: project.zoomRegions,
        cursorAnimationConfig: project.cursorAnimationConfig,
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
        bypassVelocityFilter: true,
      );

      expect(pass.filteredCursorVelocity, equals(pass.rawCursorVelocity));
    });
  });
}
