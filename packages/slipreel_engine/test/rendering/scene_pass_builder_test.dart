import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_motion_controller.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

const Size _videoSize = Size(1920, 1080);

CursorRecording _record(
  List<({int micros, double x, double y, bool clicked})> samples,
) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(
      CursorPosition(
        x: s.x,
        y: s.y,
        timestampMicros: s.micros,
        isClicked: s.clicked,
      ),
    );
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
    out.add((micros: t * 1000, x: start.dx + dx, y: start.dy, clicked: false));
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

    test('propagates cursor velocity to the bounded gate '
        '(gate stays engaged while cursor moves through dz)', () {
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
      expect(
        pass.rawCursorVelocity.distance,
        greaterThan(200),
        reason: 'Builder must compute cursor scene velocity from the recording',
      );

      // And the gate must be engaged: cursor crossed the dz boundary
      // moving fast, gate did not flap to released mid-flight.
      expect(
        builder.focal.inFlight,
        isTrue,
        reason:
            'With cursorVelocity > 80 px/s, bounded gate must remain '
            'engaged across the deadzone instead of releasing each frame',
      );
    });

    test('predictive follow mode focals on the sprite cursor (no median)', () {
      // Predictive no longer diverges from the sprite at the scene-builder
      // level — the look-ahead now lives in PredictiveFollowStrategy. So the
      // focal cursor handed to the controller equals the sprite position.
      final builder = ScenePassBuilder();
      final project = _projectWith(
        zooms: [
          _predictive(
            startTime: Duration.zero,
            duration: const Duration(seconds: 2),
            rect: const Rect.fromLTWH(960, 540, 0, 0),
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
      expect(pass.motion, isNotNull);
      expect(pass.cursorForFocal, isNotNull);
      expect(
        (pass.cursorForFocal! - pass.motion!.screenPos).distance,
        lessThan(0.001),
        reason: 'predictive focal cursor == sprite once median is removed',
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
      expect(
        pass.cursorForFocal,
        equals(pass.motion!.screenPos),
        reason:
            'Non-predictive follow modes feed the motion sprite to the focal',
      );
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

    test('shared-edge: at t == A.endTime == B.startTime, A wins and '
        'activeZoom stays non-null across the seam', () {
      // Two abutting bounded zooms: A [0s, 2s], B [2s, 4s]. The
      // exit-ramp completion frame at exactly t=2s must:
      //   - resolve to A via ZoomRegion.activeAt (earlier wins by loop
      //     order at the closed end edge), AND
      //   - flow through ScenePassBuilder so ScenePass.activeZoom is
      //     non-null AND === A (no one-frame "no zoom" drop-out
      //     between adjacent regions).
      // This guards every call site that was migrated to activeAt:
      // a regression to bare isActive at the seam would either drop
      // activeZoom or hand the frame to B.
      final a = _bounded(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(480, 270, 0, 0),
      );
      final b = _bounded(
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        rect: const Rect.fromLTWH(1440, 810, 0, 0),
      );

      // 1) Helper-level contract.
      expect(
        ZoomRegion.activeAt(const Duration(seconds: 2), [a, b]),
        same(a),
        reason:
            'At the shared edge, earlier region wins via activeAt loop order',
      );

      // 2) ScenePassBuilder propagates that decision through to
      //    ScenePass.activeZoom at the seam.
      final builder = ScenePassBuilder();
      final project = _projectWith(zooms: [a, b]);
      final recording = _eastBoundRecording(durationMs: 2200);

      // Prime the builder up through the seam.
      _drive(
        builder,
        project: project,
        recording: recording,
        from: Duration.zero,
        to: const Duration(seconds: 2) - const Duration(milliseconds: 16),
      );

      final atSeam = builder.build(
        position: const Duration(seconds: 2),
        zoomRegions: project.zoomRegions,
        cursorAnimationConfig: project.cursorAnimationConfig,
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
      );

      expect(
        atSeam.activeZoom,
        isNotNull,
        reason:
            'Closed end-edge lookup must keep the exit-ramp completion '
            'frame attributed to a zoom',
      );
      expect(
        atSeam.activeZoom,
        same(a),
        reason: 'Earlier region wins at the shared edge',
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

    test('build forwards screenRampCurve into the focal enter ramp', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 400, 400),
        startTime: Duration.zero,
        duration: const Duration(milliseconds: 3000),
        zoomLevel: 2.0,
        enterDuration: const Duration(milliseconds: 500),
        exitDuration: Duration.zero,
        followCursor: true,
        followMode: FollowMode.centered,
      );
      final recording = CursorRecording();
      for (var ms = 0; ms <= 3000; ms += 16) {
        recording.addPosition(
          CursorPosition(x: 1700, y: 950, timestampMicros: ms * 1000),
        );
      }
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      const videoSize = Size(1920, 1080);

      Offset focalAt250(Curve curve) {
        final b = ScenePassBuilder();
        Offset last = Offset.zero;
        for (var ms = 0; ms <= 250; ms += 16) {
          final p = b.build(
            position: Duration(milliseconds: ms),
            zoomRegions: [region],
            cursorAnimationConfig: cfg,
            cursorRecording: recording,
            videoSize: videoSize,
            fps: 60,
            hasCursorData: true,
            screenRampCurve: curve,
          );
          last = p.focalUpdate!.focal;
        }
        return last;
      }

      expect(
        (focalAt250(Curves.linear) - focalAt250(Curves.easeInOutQuad)).distance,
        greaterThan(1.0),
      );
    });

    test('followCursor enter-hold handoff does not chase a lagging '
        'smoothed cursor', () {
      // This drives the whole runtime path, not just ZoomFocalController:
      // the cursor spring is primed before the zoom, the raw cursor jumps to
      // a corner at zoom start, and the first post-enter frame still sees a
      // lagging smoothed sprite. The camera should keep the painted focal on
      // the enter target while that parked sprite catches up.
      final region = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: const Duration(milliseconds: 500),
        duration: const Duration(milliseconds: 2000),
        zoomLevel: 2.0,
        enterDuration: const Duration(milliseconds: 200),
        exitDuration: Duration.zero,
        followCursor: true,
        followMode: FollowMode.centered,
        followDuration: const Duration(milliseconds: 100),
      );
      final project = _projectWith(zooms: [region]);
      final recording = CursorRecording();
      for (var ms = 0; ms <= 1200; ms += 16) {
        final parked = ms >= 500;
        recording.addPosition(
          CursorPosition(
            x: parked ? 300 : 960,
            y: parked ? 220 : 540,
            timestampMicros: ms * 1000,
          ),
        );
      }

      final builder = ScenePassBuilder();
      ScenePass? pass;
      for (var ms = 0; ms <= 716; ms += 16) {
        pass = builder.build(
          position: Duration(milliseconds: ms),
          zoomRegions: project.zoomRegions,
          cursorAnimationConfig: project.cursorAnimationConfig,
          cursorDelay: project.cursorDelay,
          cursorPostProcess: project.cursorPostProcess,
          cursorRecording: recording,
          videoSize: _videoSize,
          fps: 60,
          hasCursorData: true,
        );
      }

      final settleTarget = ZoomTransformer.clampFocalToBounds(
        pass!.enterCursorTarget!,
        _videoSize,
        region.zoomLevel,
      );
      final paintedFocal = ZoomTransformer.clampFocalToBounds(
        pass.focalUpdate!.focal,
        _videoSize,
        region.zoomLevel,
      );
      expect(
        (paintedFocal - settleTarget).distance,
        // Smooth now chases the geometrically-smoothed path (Task 6):
        // the Gaussian window looks up to 2sigma (160ms) ahead, so it
        // starts curving toward the post-jump parked position ~100ms
        // before the raw cursor actually jumps there. That earlier
        // curve-in is the intended "rounds a corner" behavior (see
        // cursor_path_smoothing_test.dart), and it nudges this
        // particular excursion. The focal spring now gives followDuration its
        // truthful T95 meaning, so this deliberately-fast 100ms fixture can
        // move ~11px on the first hold frame. Keep the bound tight enough to
        // reject the old hundreds-of-pixels yank while accepting that intended
        // faster response.
        lessThan(15.0),
        reason:
            'the runtime builder should not let the hold phase yank '
            'the camera toward the lagging smoothed cursor',
      );
    });

    test('enter settle target is sampled at the SQUEEZED enter-ramp end', () {
      // A followCursor region shorter than its own feel-scaled ramps gets a
      // proportional squeeze (ZoomRegion.resolvedRampsUs) in the transform
      // and focal math. The settle-target sampling must use the SAME
      // squeezed end, or it aims the camera at a cursor position the zoom
      // never reaches — and a squeezed region has no hold in which the
      // spring could correct.
      //
      // 500ms enter + 500ms exit at the Smooth preset's 1.7x feel scale is
      // 850ms + 850ms = 1700ms of ramp in a 950ms region, so both are
      // squeezed by 950/1700: the enter ramp truly ends at 475ms, not 850ms.
      const rampDurationScale = 1.7; // ScreenAnimationStyle.smooth
      final region = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: Duration.zero,
        duration: const Duration(milliseconds: 950),
        zoomLevel: 2.0,
        enterDuration: const Duration(milliseconds: 500),
        exitDuration: const Duration(milliseconds: 500),
        followCursor: true,
      );
      expect(region.resolvedRampsUs(rampDurationScale).enterUs, 475000);

      // Cursor runs east at 600 px/s from x=100, so the two candidate
      // sample times are 225px apart and cannot be confused.
      final recording = _eastBoundRecording(
        durationMs: 1500,
        start: const Offset(100, 540),
      );
      const squeezedX = 100 + 600 * 0.475; // 385
      const unsqueezedX = 100 + 600 * 0.850; // 610

      final pass = ScenePassBuilder().build(
        position: const Duration(milliseconds: 16),
        zoomRegions: [region],
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth,
        ),
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
        rampDurationScale: rampDurationScale,
      );

      expect(pass.enterCursorTarget, isNotNull);
      expect(
        pass.enterCursorTarget!.dx,
        closeTo(squeezedX, 1.0),
        reason: 'settle target must be sampled at the squeezed ramp end',
      );
      expect(
        (pass.enterCursorTarget!.dx - unsqueezedX).abs(),
        greaterThan(100.0),
        reason: 'sampling the unsqueezed ramp end mis-aims the whole zoom',
      );
    });

    test('enter settle target uses Smooth preset averaged path', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2,
        enterDuration: const Duration(milliseconds: 500),
        exitDuration: Duration.zero,
        followCursor: true,
      );
      final recording = CursorRecording();
      for (var i = 0; i <= 120; i++) {
        recording.addPosition(
          CursorPosition(
            x: 400 + i * 4,
            y: 500 + (i.isEven ? 12 : -12),
            timestampMicros: i * 16667,
          ),
        );
      }

      final pass = ScenePassBuilder().build(
        position: const Duration(milliseconds: 16),
        zoomRegions: [region],
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth,
        ),
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
      );

      expect(pass.enterCursorTarget, isNotNull);
      expect(
        (pass.enterCursorTarget!.dy - 500).abs(),
        lessThan(4.8),
        reason:
            'zoom entry must aim at the averaged cursor line rather '
            'than one side of the raw ±12px zigzag',
      );
    });

    test('per-slice disableSmoothMouse resolves to the None preset', () {
      final clips = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 1),
          disableSmoothMouse: true,
        ),
      ];
      final resolved = cursorAnimationConfigAt(
        clips: clips,
        position: const Duration(milliseconds: 500),
        base: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
      );
      expect(resolved.preset, CursorAnimationStyle.none);
    });

    test('enter target resolves smoothing at the target slice', () {
      final clips = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 250),
        ),
        ClipSlice(
          cutStart: const Duration(milliseconds: 250),
          cutEnd: const Duration(seconds: 1),
          disableSmoothMouse: true,
        ),
      ];
      final recording = _record([
        for (var i = 0; i <= 100; i++)
          (
            micros: i * 10000,
            x: 400.0 + i,
            y: 500.0 + (i.isEven ? 12.0 : -12.0),
            clicked: false,
          ),
      ]);
      final region = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2,
        enterDuration: const Duration(milliseconds: 500),
        exitDuration: Duration.zero,
        followCursor: true,
      );

      final pass = ScenePassBuilder().build(
        position: const Duration(milliseconds: 100),
        zoomRegions: [region],
        clips: clips,
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth,
        ),
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
      );

      expect(pass.enterCursorTarget!.dy, closeTo(512, 1e-9));
    });

    test('zero-sigma enter target cannot sample before a hard cut', () {
      final clips = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 1)),
        ClipSlice(
          cutStart: const Duration(seconds: 2),
          cutEnd: const Duration(milliseconds: 2100),
        ),
      ];
      final recording = _record([
        (micros: 1900000, x: 100, y: 100, clicked: false),
        (micros: 2000000, x: 900, y: 500, clicked: false),
        (micros: 2100000, x: 900, y: 500, clicked: false),
      ]);
      final region = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: const Duration(seconds: 2),
        duration: const Duration(milliseconds: 500),
        zoomLevel: 2,
        enterDuration: const Duration(milliseconds: 100),
        exitDuration: Duration.zero,
        followCursor: true,
      );

      final pass = ScenePassBuilder().build(
        position: const Duration(seconds: 2),
        zoomRegions: [region],
        clips: clips,
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.none,
        ),
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
        cursorDelay: const Duration(milliseconds: 200),
      );

      expect(pass.enterCursorTarget, const Offset(900, 500));
    });

    test('non-contiguous cut clears emitted cursor history', () {
      final clips = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 1)),
        ClipSlice(
          cutStart: const Duration(seconds: 2),
          cutEnd: const Duration(seconds: 3),
        ),
      ];
      final recording = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 3000000, x: 600, y: 0, clicked: false),
      ]);
      final builder = ScenePassBuilder();
      for (final t in [900, 1500, 2000]) {
        builder.build(
          position: Duration(milliseconds: t),
          zoomRegions: const [],
          clips: clips,
          cursorAnimationConfig: const CursorAnimationConfig.preset(
            CursorAnimationStyle.smooth,
          ),
          cursorRecording: recording,
          videoSize: _videoSize,
          fps: 60,
          hasCursorData: true,
        );
      }

      expect(
        builder.motion.positionAt(const Duration(milliseconds: 1950)),
        isNull,
      );
      expect(builder.motion.positionAt(const Duration(seconds: 2)), isNotNull);
    });

    test('clip-list deletion cannot dereference a stale prior index', () {
      final original = [
        for (var i = 0; i < 3; i++)
          ClipSlice(
            cutStart: Duration(seconds: i),
            cutEnd: Duration(seconds: i + 1),
          ),
      ];
      final recording = _eastBoundRecording(durationMs: 3000);
      final builder = ScenePassBuilder();
      builder.build(
        position: const Duration(milliseconds: 2500),
        zoomRegions: const [],
        clips: original,
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.medium,
        ),
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
      );

      expect(
        () => builder.build(
          position: const Duration(milliseconds: 1500),
          zoomRegions: const [],
          clips: original.take(2).toList(),
          cursorAnimationConfig: const CursorAnimationConfig.preset(
            CursorAnimationStyle.medium,
          ),
          cursorRecording: recording,
          videoSize: _videoSize,
          fps: 60,
          hasCursorData: true,
        ),
        returnsNormally,
      );
    });

    test('direct hard cut resets focal momentum and filtered velocity', () {
      final clips = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 1)),
        ClipSlice(
          cutStart: const Duration(seconds: 2),
          cutEnd: const Duration(seconds: 3),
        ),
      ];
      final recording = _eastBoundRecording(durationMs: 3000, pxPerSec: 300);
      final region = _bounded(
        startTime: Duration.zero,
        duration: const Duration(seconds: 3),
      );
      final builder = ScenePassBuilder();
      for (final t in [800, 900]) {
        builder.build(
          position: Duration(milliseconds: t),
          zoomRegions: [region],
          clips: clips,
          cursorAnimationConfig: const CursorAnimationConfig.preset(
            CursorAnimationStyle.medium,
          ),
          cursorRecording: recording,
          videoSize: _videoSize,
          fps: 60,
          hasCursorData: true,
        );
      }
      final afterCut = builder.build(
        position: const Duration(seconds: 2),
        zoomRegions: [region],
        clips: clips,
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.medium,
        ),
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
      );

      expect(afterCut.rawCursorVelocity, Offset.zero);
      expect(afterCut.filteredCursorVelocity, Offset.zero);
      expect(builder.focal.focalVelocity, Offset.zero);
    });

    test('contiguous speed boundary integrates the exact wall-time delta', () {
      final clips = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 100),
          playbackSpeed: 1,
        ),
        ClipSlice(
          cutStart: const Duration(milliseconds: 100),
          cutEnd: const Duration(seconds: 1),
          playbackSpeed: 2,
        ),
      ];
      final recording = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 1000, y: 0, clicked: false),
        (micros: 1000000, x: 1000, y: 0, clicked: false),
      ]);
      const config = CursorAnimationConfig.preset(CursorAnimationStyle.medium);
      final builder = ScenePassBuilder();
      builder.build(
        position: const Duration(milliseconds: 84),
        zoomRegions: const [],
        clips: clips,
        cursorAnimationConfig: config,
        cursorRecording: recording,
        videoSize: _videoSize,
        fps: 60,
        hasCursorData: true,
      );
      final actual = builder
          .build(
            position: const Duration(milliseconds: 116),
            zoomRegions: const [],
            clips: clips,
            cursorAnimationConfig: config,
            cursorRecording: recording,
            videoSize: _videoSize,
            fps: 60,
            hasCursorData: true,
          )
          .motion!;

      final reference = CursorMotionController();
      reference.update(
        position: const Duration(milliseconds: 84),
        cursorRecording: recording,
        config: config,
        fps: 60,
        playbackSpeed: 1,
        clipStart: Duration.zero,
        clipEnd: const Duration(seconds: 1),
      );
      final expected = reference.update(
        position: const Duration(milliseconds: 116),
        cursorRecording: recording,
        config: config,
        fps: 60,
        playbackSpeed: 2,
        clipStart: Duration.zero,
        clipEnd: const Duration(seconds: 1),
        elapsedWallTime: const Duration(milliseconds: 24),
      )!;

      expect((actual.screenPos - expected.screenPos).distance, lessThan(1e-9));
      expect(
        actual.screenPos.dx,
        lessThan(1000),
        reason: 'boundary must not snap',
      );
    });

    test('delay and Smooth remain continuous across a contiguous split', () {
      final split = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 100),
        ),
        ClipSlice(
          cutStart: const Duration(milliseconds: 100),
          cutEnd: const Duration(milliseconds: 300),
        ),
      ];
      final whole = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 300),
        ),
      ];
      final recording = _eastBoundRecording(durationMs: 300, pxPerSec: 1000);
      const config = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);

      Offset drive(List<ClipSlice> clips) {
        final builder = ScenePassBuilder();
        ScenePass? pass;
        for (final milliseconds in [80, 90, 100, 110]) {
          pass = builder.build(
            position: Duration(milliseconds: milliseconds),
            zoomRegions: const [],
            clips: clips,
            cursorAnimationConfig: config,
            cursorRecording: recording,
            videoSize: _videoSize,
            fps: 60,
            hasCursorData: true,
            cursorDelay: const Duration(milliseconds: 50),
          );
        }
        return pass!.motion!.screenPos;
      }

      expect((drive(split) - drive(whole)).distance, lessThan(1e-9));
    });

    test('camera settle time is stable across playback speeds', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2,
        enterDuration: Duration.zero,
        exitDuration: Duration.zero,
        followCursor: true,
        followMode: FollowMode.centered,
        followDuration: const Duration(milliseconds: 400),
      );
      final recording = _record([
        (micros: 0, x: 960, y: 540, clicked: false),
        (micros: 1, x: 1500, y: 540, clicked: false),
        (micros: 1000000, x: 1500, y: 540, clicked: false),
      ]);

      Offset drive(double speed) {
        final builder = ScenePassBuilder();
        final clips = [
          ClipSlice(
            cutStart: Duration.zero,
            cutEnd: const Duration(seconds: 1),
            playbackSpeed: speed,
          ),
        ];
        ScenePass? pass;
        for (var frame = 0; frame <= 10; frame++) {
          pass = builder.build(
            position: Duration(microseconds: (frame * 16000 * speed).round()),
            zoomRegions: [region],
            clips: clips,
            cursorAnimationConfig: const CursorAnimationConfig.preset(
              CursorAnimationStyle.none,
            ),
            cursorRecording: recording,
            videoSize: _videoSize,
            fps: 60,
            hasCursorData: true,
          );
        }
        return pass!.focalUpdate!.focal;
      }

      expect((drive(1) - drive(2)).distance, lessThan(0.5));
    });
  });
}
