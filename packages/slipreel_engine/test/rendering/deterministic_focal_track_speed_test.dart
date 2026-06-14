import 'package:flutter/painting.dart' show Size, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _ramp() {
  final r = CursorRecording();
  for (int i = 0; i <= 80; i++) {
    r.addPosition(CursorPosition(
        x: 200.0 + i * 20.0, y: 540, timestampMicros: i * 16000, isClicked: false));
  }
  return r;
}

void main() {
  const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
  const videoSize = Size(1920, 1080);

  // A bounded-follow zoom region so the focal tracks the cursor sprite.
  // ZoomRegion uses startTime + duration (endTime is a derived getter), so
  // the region runs [100ms, 1200ms).
  final region = ZoomRegion(
    startTime: const Duration(milliseconds: 100),
    duration: const Duration(milliseconds: 1100),
    rect: const Rect.fromLTWH(660, 390, 600, 300),
    zoomLevel: 2.0,
    followMode: FollowMode.bounded,
  );

  DeterministicFocalTrack track(List<ClipSlice> clips) =>
      DeterministicFocalTrack.build(
        region: region,
        cursorRecording: _ramp(),
        cursorAnimationConfig: cfg,
        videoSize: videoSize,
        fps: 60,
        clips: clips,
      );

  test('clips defaults to empty → matches an explicit 1× slice', () {
    final t1x = track([
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(milliseconds: 1300),
        playbackSpeed: 1.0,
      )
    ]);
    final tEmpty = track(const []);
    // Sample several timestamps; focal trajectory must be identical.
    for (final ms in [200, 500, 900]) {
      final t = Duration(milliseconds: ms);
      expect((t1x.focalAt(t) - tEmpty.focalAt(t)).distance, lessThan(1e-6),
          reason: 'at $ms ms');
    }
  });

  test('a 2× slice yields a different focal trajectory than 1×', () {
    final t2x = track([
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(milliseconds: 1300),
        playbackSpeed: 2.0,
      )
    ]);
    final t1x = track(const []);
    // The speed-aware cursor lags more, so the camera focal it produces
    // differs somewhere along the region.
    var maxDelta = 0.0;
    for (final ms in [200, 400, 600, 800, 1000]) {
      final t = Duration(milliseconds: ms);
      final d = (t2x.focalAt(t) - t1x.focalAt(t)).distance;
      if (d > maxDelta) maxDelta = d;
    }
    expect(maxDelta, greaterThan(1.0));
  });

  test('matches() invalidates when clip speed changes', () {
    final t = track(const []);
    expect(
      t.matches(
        region: region,
        cursorRecording: t.cursorRecording,
        cursorAnimationConfig: cfg,
        cursorPostProcess: CursorPostProcess.none,
        videoSize: videoSize,
        fps: 60,
        clips: const [],
      ),
      isTrue,
    );
    expect(
      t.matches(
        region: region,
        cursorRecording: t.cursorRecording,
        cursorAnimationConfig: cfg,
        cursorPostProcess: CursorPostProcess.none,
        videoSize: videoSize,
        fps: 60,
        clips: [
          ClipSlice(
            cutStart: Duration.zero,
            cutEnd: const Duration(milliseconds: 1300),
            playbackSpeed: 2.0,
          )
        ],
      ),
      isFalse,
    );
  });
}
