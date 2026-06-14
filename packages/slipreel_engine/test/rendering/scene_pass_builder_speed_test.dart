import 'package:flutter/painting.dart' show Size;
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
}
