import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';

// Helpers mirrored from auto_zoom_detector_test.dart
CursorPosition _p({
  required int ms,
  required bool clicked,
  double x = 100,
  double y = 100,
}) =>
    CursorPosition(
      x: x,
      y: y,
      timestampMicros: ms * 1000,
      isClicked: clicked,
      state: CursorState.arrow,
    );

CursorRecording _rec(List<CursorPosition> positions) {
  final r = CursorRecording();
  for (final p in positions) {
    r.addPosition(p);
  }
  return r;
}

List<CursorPosition> _clickAt({
  required int atMs,
  required double x,
  required double y,
  int holdMs = 50,
}) {
  return [
    _p(ms: atMs - 16, clicked: false, x: x, y: y),
    _p(ms: atMs, clicked: true, x: x, y: y),
    _p(ms: atMs + holdMs, clicked: true, x: x, y: y),
    _p(ms: atMs + holdMs + 16, clicked: false, x: x, y: y),
  ];
}

void main() {
  test('auto-detected click zooms default to 3D subtle', () {
    // Single isolated click — smallest fixture from auto_zoom_detector_test.dart
    const detector = AutoZoomDetector();
    const videoSize = Size(1920, 1080);
    const videoDuration = Duration(seconds: 30);

    final cursor = _rec(_clickAt(atMs: 5000, x: 800, y: 600));
    final regions = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );

    expect(regions, isNotEmpty);
    expect(regions.first.tilt, const Tilt3D(style: ZoomTiltStyle.subtle));
    expect(regions.first.movement, const ZoomMovement());
  });

  test('auto-detected zooms carry the requested look', () {
    const detector = AutoZoomDetector();
    const videoSize = Size(1920, 1080);
    const videoDuration = Duration(seconds: 30);

    final cursor = _rec(_clickAt(atMs: 5000, x: 800, y: 600));
    final regions = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
      look: ZoomLook.showcase,
    );

    expect(regions, isNotEmpty);
    for (final r in regions) {
      expect(ZoomLook.of(r), ZoomLook.showcase);
    }
  });
}
