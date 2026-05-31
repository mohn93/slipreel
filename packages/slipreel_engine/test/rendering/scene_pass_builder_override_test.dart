import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';

void main() {
  test('activeRegionOverride wins even when playhead is outside all regions',
      () {
    // A real region runs 5..8s.
    final real = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: const Duration(seconds: 5),
      duration: const Duration(seconds: 3),
      zoomLevel: 2.0,
      followCursor: false,
    );
    // Synthetic override with a different focal.
    final override = ZoomRegion(
      rect: const Rect.fromLTWH(800, 600, 960, 540),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
      followCursor: false,
    );

    final builder = ScenePassBuilder();
    // Playhead at 2s — outside any real region; would normally produce
    // no zoom.
    final pass = builder.build(
      position: const Duration(seconds: 2),
      zoomRegions: [real],
      cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth),
      cursorRecording: CursorRecording(),
      videoSize: const Size(1920, 1080),
      fps: 60,
      hasCursorData: false,
      activeRegionOverride: override,
    );

    // The focal controller's target should be the override region,
    // not "no zoom".
    expect(pass.focalUpdate, isNotNull);
    expect(pass.focalUpdate!.zoom.zoomLevel, closeTo(2.0, 1e-6));
  });

  test('null override falls back to activeAt', () {
    final real = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: const Duration(seconds: 1),
      duration: const Duration(seconds: 3),
      zoomLevel: 2.0,
      followCursor: false,
    );
    final builder = ScenePassBuilder();
    // Playhead at 0.5s — no region active, no override.
    final pass = builder.build(
      position: const Duration(milliseconds: 500),
      zoomRegions: [real],
      cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth),
      cursorRecording: CursorRecording(),
      videoSize: const Size(1920, 1080),
      fps: 60,
      hasCursorData: false,
    );
    // No region is active → focalUpdate is null.
    expect(pass.focalUpdate, isNull);
  });
}
