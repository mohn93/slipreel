import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';

CursorRecording _recording() {
  final r = CursorRecording();
  for (var t = 0; t < 3000; t += 16) {
    r.addPosition(CursorPosition(
      x: 100.0 + t * 0.1,
      y: 100.0 + t * 0.05,
      timestampMicros: t * 1000,
      isClicked: false,
    ));
  }
  return r;
}

ZoomRegion _region(int startMs) => ZoomRegion(
      rect: const Rect.fromLTWH(100, 100, 400, 300),
      startTime: Duration(milliseconds: startMs),
      duration: const Duration(milliseconds: 500),
      zoomLevel: 2.0,
      videoBounds: const Size(1280, 720),
    );

void main() {
  test(
    'alternating queries across adjacent regions reuse cached tracks '
    '(no per-query thrash)',
    () {
      // The frame loop queries the current region AND (via the blur
      // exposure window) its neighbor every frame near a boundary. A
      // single-slot cache rebuilt a full ScenePassBuilder replay on
      // every alternation.
      final cache = DeterministicFocalTrackCache();
      final recording = _recording();
      final a = _region(0);
      final b = _region(500);

      DeterministicFocalTrack get(ZoomRegion r) => cache.getOrBuild(
            region: r,
            cursorRecording: recording,
            cursorAnimationConfig: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
            videoSize: const Size(1280, 720),
            fps: 30,
          );

      final a1 = get(a);
      final b1 = get(b);
      for (var round = 0; round < 3; round++) {
        expect(identical(get(a), a1), isTrue,
            reason: 'region A track must be reused across alternations');
        expect(identical(get(b), b1), isTrue,
            reason: 'region B track must be reused across alternations');
      }
      expect(cache.buildCount, 2,
          reason: 'two regions queried alternately must build exactly '
              'two tracks, ever');
    },
  );

  test('capacity evicts least-recently-used, not most', () {
    final cache = DeterministicFocalTrackCache(capacity: 2);
    final recording = _recording();
    final a = _region(0);
    final b = _region(500);
    final c = _region(1000);

    DeterministicFocalTrack get(ZoomRegion r) => cache.getOrBuild(
          region: r,
          cursorRecording: recording,
          cursorAnimationConfig: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
          videoSize: const Size(1280, 720),
          fps: 30,
        );

    get(a);
    final b1 = get(b);
    get(c); // evicts a (LRU)
    expect(cache.buildCount, 3);
    expect(identical(get(b), b1), isTrue,
        reason: 'b was more recently used than a and must survive');
    expect(cache.buildCount, 3);
    get(a); // a was evicted -> rebuild
    expect(cache.buildCount, 4);
  });

  test('a changed input invalidates only that lookup, not via aliasing',
      () {
    final cache = DeterministicFocalTrackCache();
    final recording = _recording();
    final a = _region(0);

    final t1 = cache.getOrBuild(
      region: a,
      cursorRecording: recording,
      cursorAnimationConfig: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
      videoSize: const Size(1280, 720),
      fps: 30,
    );
    // Same region, different fps -> distinct track, old entry retained.
    final t2 = cache.getOrBuild(
      region: a,
      cursorRecording: recording,
      cursorAnimationConfig: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
      videoSize: const Size(1280, 720),
      fps: 60,
    );
    expect(identical(t1, t2), isFalse);
    expect(cache.buildCount, 2);
  });
}
