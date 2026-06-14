import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _ramp() {
  final r = CursorRecording();
  for (int i = 0; i <= 40; i++) {
    r.addPosition(CursorPosition(
        x: i * 50.0, y: 0, timestampMicros: i * 16000, isClicked: false));
  }
  return r;
}

void main() {
  const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
  const videoSize = Size(1920, 1080);

  ScenePass driveBuilder(ScenePassBuilder b, List<ClipSlice> clips) {
    late ScenePass pass;
    for (int i = 0; i <= 10; i++) {
      pass = b.build(
        position: Duration(microseconds: i * 16000),
        zoomRegions: const [],
        cursorAnimationConfig: cfg,
        cursorRecording: _ramp(),
        videoSize: videoSize,
        fps: 60,
        hasCursorData: true,
        clips: clips,
      );
    }
    return pass;
  }

  test('build() forwards slice playbackSpeed at the source position', () {
    // A 2× slice spanning the recording must produce a softer (more
    // lagging → smaller dx) sprite at a given source position than an
    // empty clip list (which resolves to speed 1.0).
    final slice = ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(milliseconds: 640),
      playbackSpeed: 2.0,
    );
    final fast = driveBuilder(ScenePassBuilder(), [slice]);
    final norm = driveBuilder(ScenePassBuilder(), const []);
    expect(fast.motion!.screenPos.dx, lessThan(norm.motion!.screenPos.dx));
  });

  test('empty clips list matches an explicit 1× slice (unchanged)', () {
    final empty = driveBuilder(ScenePassBuilder(), const []);
    final oneX = driveBuilder(ScenePassBuilder(), [
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(milliseconds: 640),
        playbackSpeed: 1.0,
      )
    ]);
    expect(empty.motion!.screenPos.dx,
        closeTo(oneX.motion!.screenPos.dx, 1e-9));
  });

  test('preview-style and export-style cursor stepping converge for a '
      'sped-up slice (bounded, step-granularity discretization)', () {
    // EXPORT steps source time in uniform fine increments (1/60 s);
    // PREVIEW at 2× advances source ~2× per wall frame, so it steps
    // coarser. The speed-aware spring is closed-form, so the ONLY
    // difference at a shared source position is the piecewise-constant
    // feedforward/raw target held stale across each step — an inherent
    // discretization that scales with step size and cursor speed and
    // also exists pre-feature (it's the step-granularity mismatch at any
    // non-1× speed, NOT a preview/export logic divergence; at 1× the
    // granularities are equal and the two are identical). This test pins
    // that the gap stays bounded and shrinks as the preview step
    // approaches the export step.
    final slice = ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(milliseconds: 800),
      playbackSpeed: 2.0,
    );

    Offset driveStepped(int stepMicros) {
      final b = ScenePassBuilder();
      late ScenePass pass;
      ScenePass step(int us) => pass = b.build(
            position: Duration(microseconds: us),
            zoomRegions: const [],
            cursorAnimationConfig: const CursorAnimationConfig.preset(
                CursorAnimationStyle.smooth),
            cursorRecording: _ramp(),
            videoSize: const Size(1920, 1080),
            fps: 60,
            hasCursorData: true,
            clips: [slice],
          );
      for (int us = 0; us < 480000; us += stepMicros) {
        step(us);
      }
      // Land every regime on the SAME final source position so the
      // comparison isolates step-granularity discretization (not a
      // different point on the ramp).
      step(480000);
      return pass.motion!.screenPos;
    }

    final exportStyle = driveStepped(16667); // ~1/60 s (export)
    final coarse = (driveStepped(33333) - exportStyle).distance; // 2× preview
    final mid = (driveStepped(20834) - exportStyle).distance;    // 1.25× step

    // Bounded: a gross divergence (e.g. broken speed resolution) would
    // blow this far past the inherent ~30 px target-staleness gap.
    expect(coarse, lessThan(60.0));
    // Convergent: as the preview step approaches the export step, the
    // discretization gap shrinks toward zero.
    expect(mid, lessThan(coarse));
  });
}
