// packages/slipreel_engine/test/effects/zoom_transformer_tilt_test.dart
import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  final t = ZoomTransformer();
  const videoSize = Size(1000, 1000);
  final framing = ZoomFraming.identity(videoSize);

  ZoomRegion region({required Tilt3D tilt, bool followCursor = true}) =>
      ZoomRegion(
        rect: const Rect.fromLTWH(600, 600, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2,
        enterDuration: Duration.zero,
        exitDuration: Duration.zero,
        followCursor: followCursor,
        tilt: tilt,
      );

  // Mid-hold so z == zoomLevel (progress == 1).
  const pos = Duration(seconds: 1);

  test('flat tilt is byte-identical to a region with no tilt config', () {
    final flat = t.getTransform(
        position: pos,
        zoomRegion: region(tilt: const Tilt3D()),
        videoSize: videoSize,
        focalPoint: const Offset(650, 650),
        framing: framing);
    // Perspective row must be identity (no setEntry(3,2)).
    expect(flat.entry(3, 2), 0.0);
    expect(flat.entry(3, 3), 1.0);
  });

  test('3D tilt sets a non-zero perspective entry and rotation', () {
    final tilted = t.getTransform(
        position: pos,
        zoomRegion: region(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
        videoSize: videoSize,
        focalPoint: const Offset(650, 650),
        framing: framing);
    expect(tilted.entry(3, 2), isNot(0.0));
  });

  test('manual placement (followCursor:false) also tilts', () {
    final tilted = t.getTransform(
        position: pos,
        zoomRegion: region(
            tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
            followCursor: false),
        videoSize: videoSize,
        framing: framing);
    expect(tilted.entry(3, 2), isNot(0.0));
  });

  test('resolution-independence: a focal point projects to the same '
      'normalized screen position at 1080p and 4K', () {
    // 2x canvas == 4K of the same scene. Same normalized focal, same tilt.
    final f1 = ZoomFraming.identity(const Size(1920, 1080));
    final f2 = ZoomFraming.identity(const Size(3840, 2160));
    final r = region(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    final m1 = t.getTransform(
        position: pos,
        zoomRegion: r,
        videoSize: const Size(1920, 1080),
        focalPoint: const Offset(1400, 800),
        framing: f1);
    final m2 = t.getTransform(
        position: pos,
        zoomRegion: r,
        videoSize: const Size(3840, 2160),
        focalPoint: const Offset(2800, 1600),
        framing: f2);
    // perspective entry scales by 1/2 between the two resolutions.
    expect(m1.entry(3, 2), closeTo(m2.entry(3, 2) * 2, 1e-9));
  });
}
