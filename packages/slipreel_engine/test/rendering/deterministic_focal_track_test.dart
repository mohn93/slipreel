@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';

void main() {
  // A cursor that sits at (200,200) until 2500ms then sweeps to (1200,800)
  // by 4500ms.
  CursorRecording sweep() {
    final rec = CursorRecording();
    for (var ms = 0; ms <= 6000; ms += 16) {
      final x = ms < 2500
          ? 200.0
          : 200.0 +
              (1200 - 200) *
                  ((ms - 2500) / 2000).clamp(0.0, 1.0);
      final y = ms < 2500
          ? 200.0
          : 200.0 +
              (800 - 200) *
                  ((ms - 2500) / 2000).clamp(0.0, 1.0);
      rec.addPosition(CursorPosition(
        x: x,
        y: y,
        timestampMicros: ms * 1000,
      ));
    }
    return rec;
  }

  // A follow-cursor bounded zoom from 2542ms for 2000ms, centered on the
  // video. The rect's center (~864, 558) is well away from the cursor's
  // initial position (200, 200) — this makes the spring's ramp visible.
  final region = ZoomRegion(
    rect: const Rect.fromLTWH(0, 0, 1728, 1117),
    startTime: const Duration(milliseconds: 2542),
    duration: const Duration(milliseconds: 2000),
    zoomLevel: 2.0,
    followCursor: true,
    followMode: FollowMode.bounded,
  );
  const videoSize = Size(1728, 1117);

  DeterministicFocalTrack buildTrack() => DeterministicFocalTrack.build(
        region: region,
        cursorRecording: sweep(),
        cursorAnimationConfig:
            const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        videoSize: videoSize,
        fps: 60,
      );

  test('focalAt is a pure function: same t → same focal, any call order', () {
    final track = buildTrack();
    final a = track.focalAt(const Duration(milliseconds: 3000));
    track.focalAt(const Duration(milliseconds: 4000)); // perturb call order
    final b = track.focalAt(const Duration(milliseconds: 3000));
    expect(a, b);
  });

  test(
      'focal does NOT snap at region entry — moves <40px in the first 16ms',
      () {
    final track = buildTrack();
    final f0 = track.focalAt(const Duration(milliseconds: 2542));
    final f1 = track.focalAt(const Duration(milliseconds: 2558));
    expect(
      (f1 - f0).distance,
      lessThan(40.0),
      reason: 'spring ramps from rect.center; it must not teleport to the '
          'cursor in one frame (that snap was the scene-blur crack)',
    );
  });

  test('focal converges toward the cursor during the hold phase', () {
    final track = buildTrack();
    // By 1s into the 2s region the spring should have chased most of the
    // way toward the cursor at (200, 200) from the rect center (864, 558).
    final focal = track.focalAt(const Duration(milliseconds: 3600));
    expect(
      focal.dx,
      lessThan(700),
      reason: 'chased left toward cursor x=200 from center x=864',
    );
  });

  group('matches()', () {
    final recording = sweep();
    const config =
        CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
    final track = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: recording,
      cursorAnimationConfig: config,
      videoSize: videoSize,
      fps: 60,
    );

    test('identical inputs → true', () {
      expect(
        track.matches(
          region: region,
          cursorRecording: recording,
          cursorAnimationConfig: config,
          cursorPostProcess: CursorPostProcess.none,
          videoSize: videoSize,
          fps: 60,
        ),
        isTrue,
      );
    });

    test('changed region → false', () {
      final other = region.copyWith(zoomLevel: 3.0);
      expect(
        track.matches(
          region: other,
          cursorRecording: recording,
          cursorAnimationConfig: config,
          cursorPostProcess: CursorPostProcess.none,
          videoSize: videoSize,
          fps: 60,
        ),
        isFalse,
      );
    });

    test('separate but value-equal CursorAnimationConfig instances → true',
        () {
      // A distinct instance with the same preset value — must not thrash
      // the cache. Built without `const` so Dart can't canonicalize it to
      // the same object as [config]; this proves `matches` is value-based.
      // ignore: prefer_const_constructors
      final fresh =
          CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      expect(identical(config, fresh), isFalse);
      expect(
        track.matches(
          region: region,
          cursorRecording: recording,
          cursorAnimationConfig: fresh,
          cursorPostProcess: CursorPostProcess.none,
          videoSize: videoSize,
          fps: 60,
        ),
        isTrue,
      );
    });

    test('changed cursorPostProcess → false', () {
      expect(
        track.matches(
          region: region,
          cursorRecording: recording,
          cursorAnimationConfig: config,
          cursorPostProcess:
              const CursorPostProcess(removeShakes: true),
          videoSize: videoSize,
          fps: 60,
        ),
        isFalse,
      );
    });

    test('omitted cursorDelay defaults to zero — back-compat for export', () {
      // [track] was built without cursorDelay; export calls matches() without
      // it too, so a delay-less call must still match.
      expect(
        track.matches(
          region: region,
          cursorRecording: recording,
          cursorAnimationConfig: config,
          cursorPostProcess: CursorPostProcess.none,
          videoSize: videoSize,
          fps: 60,
        ),
        isTrue,
      );
    });

    test('changed cursorDelay → false', () {
      expect(
        track.matches(
          region: region,
          cursorRecording: recording,
          cursorAnimationConfig: config,
          cursorPostProcess: CursorPostProcess.none,
          videoSize: videoSize,
          fps: 60,
          cursorDelay: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });
  });

  test('cursorDelay shifts the followed focal while the cursor is moving', () {
    final rec = sweep();
    const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
    final noDelay = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: rec,
      cursorAnimationConfig: cfg,
      videoSize: videoSize,
      fps: 60,
    );
    final delayed = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: rec,
      cursorAnimationConfig: cfg,
      videoSize: videoSize,
      fps: 60,
      cursorDelay: const Duration(milliseconds: 200),
    );
    // During the cursor sweep (2500–4500ms) a 200ms delay makes the camera
    // follow an earlier, less-swept cursor — so the focal differs.
    final a = noDelay.focalAt(const Duration(milliseconds: 4000));
    final b = delayed.focalAt(const Duration(milliseconds: 4000));
    expect((a - b).distance, greaterThan(5.0));
  });
}
