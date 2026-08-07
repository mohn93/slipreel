import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/scene_blur_overlay.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';

void main() {
  test('scene-blur focal replay responds to cursorDelay behaviorally', () {
    const videoSize = Size(2000, 1000);
    final recording = CursorRecording();
    for (var i = 0; i <= 10; i++) {
      recording.addPosition(
        CursorPosition(x: 200 + i * 160, y: 500, timestampMicros: i * 100000),
      );
    }
    final region = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 2000, 1000),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2,
      enterDuration: Duration.zero,
      exitDuration: Duration.zero,
      followCursor: true,
      followMode: FollowMode.centered,
      followDuration: Duration.zero,
    );

    final withoutDelay = buildSceneBlurFocalTrack(
      region: region,
      cursorRecording: recording,
      cursorAnimationConfig: const CursorAnimationConfig.preset(
        CursorAnimationStyle.none,
      ),
      cursorPostProcess: CursorPostProcess.none,
      cursorDelay: Duration.zero,
      videoSize: videoSize,
      fps: 60,
      screenRampCurve: Curves.linear,
      rampDurationScale: 1,
      tuning: MotionTuning.defaults,
      clips: const [],
      framing: ZoomFraming.identity(videoSize),
    );
    final delayed = buildSceneBlurFocalTrack(
      region: region,
      cursorRecording: recording,
      cursorAnimationConfig: const CursorAnimationConfig.preset(
        CursorAnimationStyle.none,
      ),
      cursorPostProcess: CursorPostProcess.none,
      cursorDelay: const Duration(milliseconds: 200),
      videoSize: videoSize,
      fps: 60,
      screenRampCurve: Curves.linear,
      rampDurationScale: 1,
      tuning: MotionTuning.defaults,
      clips: const [],
      framing: ZoomFraming.identity(videoSize),
    );

    final t = const Duration(milliseconds: 800);
    expect(delayed.focalAt(t).dx, lessThan(withoutDelay.focalAt(t).dx));
    expect(
      delayed.matches(
        region: region,
        cursorRecording: recording,
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.none,
        ),
        cursorPostProcess: CursorPostProcess.none,
        cursorDelay: Duration.zero,
        videoSize: videoSize,
        fps: 60,
        screenRampCurve: Curves.linear,
        rampDurationScale: 1,
        tuning: MotionTuning.defaults,
        clips: const [],
        framing: ZoomFraming.identity(videoSize),
      ),
      isFalse,
      reason: 'changing cursorDelay must invalidate the cached replay track',
    );
  });
}
