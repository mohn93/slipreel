@TestOn('vm')
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// Pins the invariant that the exported camera focal is the one the editor
/// previewed, for follow-cursor zoom regions.
///
/// The preview renders `DeterministicFocalTrack.focalAt(t)` — a replay at a
/// fixed 16 ms step — whenever a region follows the cursor (see
/// `shouldUseDeterministicFocal` in the app shell). Export used to render
/// the live spring instead, stepped at 1/outputFps. Both integrate the same
/// spring, but at different timesteps, so the bounded deadzone gate's
/// hysteresis latches on different frames and the two paths separate for
/// the rest of a chase. The symptom was a camera offset the editor never
/// showed the user.
///
/// `1df3f710` previously routed the export's *scene-blur* focal through the
/// deterministic track for exactly this reason. It left the *render* focal
/// on the live spring; this pins the other half.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const videoSize = Size(1728, 1117);

  // A cursor parked at (200,200) until 2500ms, then sweeping to (1200,800)
  // over the next 2000ms. The sweep engages the follow gate — a stationary
  // cursor would never exercise the hysteresis this test is about.
  CursorRecording sweep() {
    final rec = CursorRecording();
    for (var ms = 0; ms <= 8000; ms += 16) {
      final t = ((ms - 2500) / 2000).clamp(0.0, 1.0);
      rec.addPosition(
        CursorPosition(
          x: 200.0 + (1200 - 200) * t,
          y: 200.0 + (800 - 200) * t,
          timestampMicros: ms * 1000,
        ),
      );
    }
    return rec;
  }

  final followRegion = ZoomRegion(
    rect: const Rect.fromLTWH(0, 0, 1728, 1117),
    startTime: const Duration(milliseconds: 2542),
    duration: const Duration(milliseconds: 4000),
    zoomLevel: 2.0,
    followCursor: true,
    followMode: FollowMode.bounded,
  );

  final anchoredRegion = ZoomRegion(
    rect: const Rect.fromLTWH(400, 300, 864, 558),
    startTime: const Duration(milliseconds: 2542),
    duration: const Duration(milliseconds: 4000),
    zoomLevel: 2.0,
    followCursor: false,
  );

  const noFrame = WindowFrame(
    name: 'None',
    padding: EdgeInsets.zero,
    cornerRadius: 0,
    shadowBlur: 0,
    shadowOffset: Offset.zero,
    shadowColor: Color(0x00000000),
    borderWidth: 0,
  );

  EditorProjectState stateFor(ZoomRegion region) =>
      EditorProjectState.defaults().copyWith(
        windowFrame: noFrame,
        zoomRegions: <ZoomRegion>[region],
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth,
        ),
      );

  FrameCompositor compositorFor(ZoomRegion region, int fps) => FrameCompositor(
    projectState: stateFor(region),
    cursorRecording: sweep(),
    metadata: RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.utc(2026, 1, 1),
      widthPx: 1728,
      heightPx: 1117,
      fps: fps,
    ),
    videoSize: videoSize,
    fps: fps,
  );

  /// The track the PREVIEW would build for this region — same inputs the
  /// compositor derives from project state, so a mismatch means the export
  /// picked a different focal, not that the two tracks were configured
  /// differently.
  DeterministicFocalTrack trackFor(ZoomRegion region, int fps) {
    final state = stateFor(region);
    return DeterministicFocalTrack.build(
      region: region,
      cursorRecording: sweep(),
      cursorAnimationConfig: state.cursorAnimationConfig,
      cursorPostProcess: state.cursorPostProcess,
      videoSize: videoSize,
      fps: fps,
      screenRampCurve: state.screenAnimationConfig.rampCurve,
      rampDurationScale: state.screenAnimationConfig.rampDurationScale,
      clips: state.timeline.clips,
    );
  }

  // Sample points inside the region's hold phase, where the deadzone gate
  // runs. Enter and exit ramps agree closely regardless of timestep; the
  // gate is where a difference compounds.
  final samplePoints = <Duration>[
    for (var ms = 3000; ms <= 6000; ms += 250) Duration(milliseconds: ms),
  ];

  test('a follow-cursor region renders the previewed deterministic focal',
      () {
    const fps = 30;
    final compositor = compositorFor(followRegion, fps);
    final track = trackFor(followRegion, fps);

    // A deliberately wrong live focal. If the compositor were still
    // rendering the spring, every sample would come back as this value and
    // the assertion would fail by hundreds of pixels — so this doubles as
    // proof the test is not passing by coincidence.
    const bogusLiveFocal = Offset(10, 10);

    var worst = 0.0;
    Duration worstAt = Duration.zero;
    for (final p in samplePoints) {
      final rendered = compositor.renderFocalFor(
        zoom: followRegion,
        liveFocal: bogusLiveFocal,
        position: p,
      );
      final previewed = track.focalAt(p);
      final d = (rendered - previewed).distance;
      if (d > worst) {
        worst = d;
        worstAt = p;
      }
    }

    expect(
      worst,
      lessThan(0.001),
      reason: 'exported focal differs from the previewed focal by '
          '${worst.toStringAsFixed(3)}px at ${worstAt.inMilliseconds}ms',
    );
  });

  test('a padded project renders the focal framed the way the preview frames '
      'it', () {
    // The preview builds its track with the project's ZoomFraming
    // (playback_canvas passes `framing:`). If export builds its track
    // without one, the two clamp the focal in different spaces and the
    // paths diverge again — invisibly, because a zero-padding fixture
    // cannot tell the two apart.
    const fps = 30;
    const padded = WindowFrame(
      name: 'Padded',
      padding: EdgeInsets.all(120),
      cornerRadius: 12,
      shadowBlur: 0,
      shadowOffset: Offset.zero,
      shadowColor: Color(0x00000000),
      borderWidth: 0,
    );

    final state = EditorProjectState.defaults().copyWith(
      windowFrame: padded,
      zoomRegions: <ZoomRegion>[followRegion],
      cursorAnimationConfig: const CursorAnimationConfig.preset(
        CursorAnimationStyle.smooth,
      ),
    );
    final compositor = FrameCompositor(
      projectState: state,
      cursorRecording: sweep(),
      metadata: RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.utc(2026, 1, 1),
        widthPx: 1728,
        heightPx: 1117,
        fps: fps,
      ),
      videoSize: videoSize,
      fps: fps,
    );

    // What the preview would render: the same track, built with the same
    // framing the compositor composes against.
    final previewTrack = DeterministicFocalTrack.build(
      region: followRegion,
      cursorRecording: sweep(),
      cursorAnimationConfig: state.cursorAnimationConfig,
      cursorPostProcess: state.cursorPostProcess,
      videoSize: videoSize,
      fps: fps,
      screenRampCurve: state.screenAnimationConfig.rampCurve,
      rampDurationScale: state.screenAnimationConfig.rampDurationScale,
      clips: state.timeline.clips,
      framing: compositor.framing,
    );

    var worst = 0.0;
    Duration worstAt = Duration.zero;
    for (final p in samplePoints) {
      final rendered = compositor.renderFocalFor(
        zoom: followRegion,
        liveFocal: const Offset(10, 10),
        position: p,
      );
      final d = (rendered - previewTrack.focalAt(p)).distance;
      if (d > worst) {
        worst = d;
        worstAt = p;
      }
    }

    expect(
      worst,
      lessThan(0.001),
      reason: 'with padding, the exported focal differs from the previewed '
          'focal by ${worst.toStringAsFixed(3)}px at '
          '${worstAt.inMilliseconds}ms',
    );
  });

  test('an anchored region still renders the live focal', () {
    // Non-follow regions carry no accumulated spring state, so there is
    // nothing to diverge and nothing to replace. Guards against the fix
    // over-reaching into the anchored path.
    final compositor = compositorFor(anchoredRegion, 30);
    const liveFocal = Offset(832, 579);

    for (final p in samplePoints) {
      expect(
        compositor.renderFocalFor(
          zoom: anchoredRegion,
          liveFocal: liveFocal,
          position: p,
        ),
        liveFocal,
      );
    }
  });

  /// Walks a fresh [ScenePassBuilder] at [fps] the way the export pipeline
  /// drives it, returning the live-spring focal at each frame. This is the
  /// signal export used to render, and it is genuinely fps-dependent — the
  /// spring integrates at 1/fps, so the deadzone gate latches on different
  /// frames.
  Map<int, Offset> liveSpringFrames(ZoomRegion region, int fps) {
    final state = stateFor(region);
    final builder = ScenePassBuilder();
    final recording = sweep();
    final stepMicros = (1000000 / fps).round();
    final out = <int, Offset>{};
    for (var us = 0; us <= 8000000; us += stepMicros) {
      final pass = builder.build(
        position: Duration(microseconds: us),
        zoomRegions: <ZoomRegion>[region],
        cursorAnimationConfig: state.cursorAnimationConfig,
        cursorRecording: recording,
        videoSize: videoSize,
        fps: fps,
        hasCursorData: true,
        screenRampCurve: state.screenAnimationConfig.rampCurve,
        rampDurationScale: state.screenAnimationConfig.rampDurationScale,
      );
      out[us] = pass.focalUpdate?.focal ?? region.rect.center;
    }
    return out;
  }

  Offset frameAtOrBefore(Map<int, Offset> frames, Duration target) {
    final keys = frames.keys.where((k) => k <= target.inMicroseconds).toList()
      ..sort();
    return frames[keys.last]!;
  }

  test('the exported focal does not depend on the output fps', () {
    // A camera path that changes with the encoder's frame rate is
    // definitionally wrong — nothing about the composition depends on how
    // often it is sampled.
    //
    // Each side is fed the live-spring focal its OWN frame rate produces,
    // which is what the export pipeline would hand the compositor. Those
    // two inputs genuinely differ; the test passes only because the
    // compositor discards them in favour of the deterministic track. Feed
    // a shared constant here instead and the test would pass trivially
    // whether or not the fix is present.
    final at30 = compositorFor(followRegion, 30);
    final at60 = compositorFor(followRegion, 60);
    final spring30 = liveSpringFrames(followRegion, 30);
    final spring60 = liveSpringFrames(followRegion, 60);

    var worstInput = 0.0;
    var worst = 0.0;
    for (final p in samplePoints) {
      final live30 = frameAtOrBefore(spring30, p);
      final live60 = frameAtOrBefore(spring60, p);
      final inputDelta = (live30 - live60).distance;
      if (inputDelta > worstInput) worstInput = inputDelta;

      final a = at30.renderFocalFor(
        zoom: followRegion,
        liveFocal: live30,
        position: p,
      );
      final b = at60.renderFocalFor(
        zoom: followRegion,
        liveFocal: live60,
        position: p,
      );
      final d = (a - b).distance;
      if (d > worst) worst = d;
    }

    // Guard the guard: if the two frame rates ever stopped producing
    // different spring focals, this test would be vacuous.
    expect(
      worstInput,
      greaterThan(1.0),
      reason: 'the live spring should differ between 30fps and 60fps; if it '
          'does not, this test no longer proves anything',
    );

    expect(
      worst,
      lessThan(1.0),
      reason: 'the exported camera path differs by '
          '${worst.toStringAsFixed(2)}px between 30fps and 60fps',
    );
  });
}
