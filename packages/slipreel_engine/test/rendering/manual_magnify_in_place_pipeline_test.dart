@TestOn('vm')
library;

// INTEGRATION GUARD for the manual "magnify-in-place" framing change.
//
// Unlike zoom_transformer_test (pure getTransform) and
// zoom_focal_controller_test (pure controller), this test drives the
// MANUAL placement through the REAL render pipeline that both the preview
// (PlaybackCanvas) and the export (FrameCompositor) consume:
//
//   ScenePassBuilder -> ZoomFocalController.update (manual branch)
//        -> ScenePass.focalUpdate.focal
//        -> ZoomTransformer.getTransform (manual centerOffsetInPlace branch)
//
// It replays that pipeline via DeterministicFocalTrack (the same shared
// replay used for scene-blur sampling — a fresh ScenePassBuilder per step)
// on a DEVICE-FRAMED edge placement, then maps the placed point through the
// resulting matrix and locks two properties:
//
//   1. PLACEMENT-STABLE-ACROSS-LEVEL: toCanvas(rect.center) lands at the
//      SAME on-screen position at zoomLevel 5 and zoomLevel 2. This is the
//      property that regressed under center-and-clamp (5x->2x lurched the
//      edge placement ~16% of the canvas inward). This test FAILS if the
//      manual path ever reverts to center-and-clamp.
//
//   2. PREVIEW == EXPORT: two independent pipeline runs (standing in for the
//      two real consumers) produce byte-identical focals AND matrices, since
//      the manual branch is fed identically to both.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

void main() {
  // A 1170x2532 portrait phone recording (the user's repro device), rendered
  // into a padded canvas with a device bezel — videoRect is inset from the
  // canvas by a uniform bezel/padding margin, exactly the geometry that made
  // the clamp boundary zoom-dependent.
  const videoSize = Size(1170, 2532);
  // Canvas larger than the video on every side (bezel + padding). The video
  // is centered inside it at 1:1 scale for simplicity.
  const canvasSize = Size(1370, 2732);
  final videoRect = Rect.fromLTWH(
    (canvasSize.width - videoSize.width) / 2, // 100
    (canvasSize.height - videoSize.height) / 2, // 100
    videoSize.width,
    videoSize.height,
  );
  final framing = ZoomFraming.device(
    videoSize: videoSize,
    videoRect: videoRect,
    canvasSize: canvasSize,
  );

  // A MANUAL placement near the TOP edge of the portrait video — the case
  // the spec measured drifting ~410px between 5x and 2x under the old clamp.
  // Centered horizontally, ~6% down from the top.
  final placementRect = Rect.fromCenter(
    center: const Offset(585, 152), // x = W/2, y ~= 0.06*H
    width: 300,
    height: 300,
  );

  // Manual placement => followCursor:false. No cursor data needed (manual
  // ignores the cursor entirely), but supply an inert recording so the
  // pipeline runs its full cursor branch the same way the real app does.
  CursorRecording emptyCursor() => CursorRecording();

  ZoomRegion manualRegion(double zoomLevel) => ZoomRegion(
        rect: placementRect,
        startTime: const Duration(milliseconds: 500),
        duration: const Duration(milliseconds: 3000),
        zoomLevel: zoomLevel,
        followCursor: false,
      );

  DeterministicFocalTrack buildTrack(double zoomLevel) =>
      DeterministicFocalTrack.build(
        region: manualRegion(zoomLevel),
        cursorRecording: emptyCursor(),
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth,
        ),
        videoSize: videoSize,
        fps: 60,
        framing: framing,
      );

  final transformer = ZoomTransformer();

  // Map the placed point (in source coords) through the full pipeline at a
  // hold-phase timestamp and return its ON-SCREEN (canvas) position.
  Offset placedScreenPos(double zoomLevel, Duration at) {
    final region = manualRegion(zoomLevel);
    final track = buildTrack(zoomLevel);
    final focal = track.focalAt(at); // pipeline focal (controller manual path)
    final matrix = transformer.getTransform(
      position: at,
      zoomRegion: region,
      videoSize: videoSize,
      focalPoint: focal,
      framing: framing,
    );
    // The matrix operates in CENTER-RELATIVE canvas coordinates (the child is
    // laid out with alignment: center). Convert the placed point to a
    // canvas-center-relative offset, transform it, and convert back.
    final canvasCenter =
        Offset(canvasSize.width / 2, canvasSize.height / 2);
    final placedCanvas = framing.debugToCanvas(placementRect.center);
    final rel = placedCanvas - canvasCenter;
    final v = matrix.transform3(Vector3(rel.dx, rel.dy, 0));
    return Offset(v.x, v.y) + canvasCenter;
  }

  // A hold-phase timestamp (well past the 200ms-ish enter ramp, well before
  // exit): zoom factor == zoomLevel.
  const holdAt = Duration(milliseconds: 2000);

  test(
    'MANUAL edge placement is placement-stable across zoom level through the '
    'full pipeline (FAILS under center-and-clamp): on-screen pos at 5x == 2x',
    () {
      final pos5 = placedScreenPos(5.0, holdAt);
      final pos2 = placedScreenPos(2.0, holdAt);
      // Magnify-in-place keeps the placed point at the same frame fraction at
      // every zoom level, so its on-screen position is identical. Under the
      // old center-and-clamp this differed by hundreds of px (the lurch).
      expect((pos5 - pos2).distance, lessThan(0.5),
          reason: 'manual placement lurched across zoom-level change — the '
              'manual path likely reverted to center-and-clamp');
    },
  );

  test(
    'MANUAL placement: preview==export — two independent pipeline runs give '
    'byte-identical focal AND transform matrix',
    () {
      final region = manualRegion(5.0);
      // Two independent runs stand in for the two real consumers (preview
      // PlaybackCanvas vs export FrameCompositor), which each own their own
      // ScenePassBuilder but are fed identical inputs + the same framing.
      final previewFocal = buildTrack(5.0).focalAt(holdAt);
      final exportFocal = buildTrack(5.0).focalAt(holdAt);
      expect(previewFocal, exportFocal,
          reason: 'manual focal must be identical for preview and export');

      final previewMatrix = transformer.getTransform(
        position: holdAt,
        zoomRegion: region,
        videoSize: videoSize,
        focalPoint: previewFocal,
        framing: framing,
      );
      final exportMatrix = transformer.getTransform(
        position: holdAt,
        zoomRegion: region,
        videoSize: videoSize,
        focalPoint: exportFocal,
        framing: framing,
      );
      expect(previewMatrix, exportMatrix,
          reason: 'preview and export zoom matrices must be byte-identical');
    },
  );

  test(
    'MANUAL placement through the pipeline never reveals void at the edge '
    '(viewport stays within the padded canvas) at z in {2,3,5}',
    () {
      // The whole point of magnify-in-place: a near-edge placement still
      // keeps the bezel/padding in frame (no empty void). Verify the visible
      // canvas window the matrix selects stays within [0, canvasSize].
      for (final z in [2.0, 3.0, 5.0]) {
        final region = manualRegion(z);
        final focal = buildTrack(z).focalAt(holdAt);
        final matrix = transformer.getTransform(
          position: holdAt,
          zoomRegion: region,
          videoSize: videoSize,
          focalPoint: focal,
          framing: framing,
        );
        final canvasCenter =
            Offset(canvasSize.width / 2, canvasSize.height / 2);
        // Invert the center-relative matrix to find which canvas region the
        // viewport corners sample. Top-left and bottom-right viewport corners
        // are at -/+ canvasSize/2 in center-relative coords.
        final inv = Matrix4.copy(matrix)..invert();
        Offset sample(Offset viewportRel) {
          final v = inv.transform3(
              Vector3(viewportRel.dx, viewportRel.dy, 0));
          return Offset(v.x, v.y) + canvasCenter;
        }

        final topLeft =
            sample(Offset(-canvasSize.width / 2, -canvasSize.height / 2));
        final bottomRight =
            sample(Offset(canvasSize.width / 2, canvasSize.height / 2));
        const eps = 0.5;
        expect(topLeft.dx, greaterThanOrEqualTo(-eps),
            reason: 'z=$z left void');
        expect(topLeft.dy, greaterThanOrEqualTo(-eps),
            reason: 'z=$z top void');
        expect(bottomRight.dx, lessThanOrEqualTo(canvasSize.width + eps),
            reason: 'z=$z right void');
        expect(bottomRight.dy, lessThanOrEqualTo(canvasSize.height + eps),
            reason: 'z=$z bottom void');
      }
    },
  );
}
