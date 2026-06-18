import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

CursorPosition _p({
  required int ms,
  required bool clicked,
  required double x,
  required double y,
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
}) =>
    [
      _p(ms: atMs - 16, clicked: false, x: x, y: y),
      _p(ms: atMs, clicked: true, x: x, y: y),
      _p(ms: atMs + holdMs, clicked: true, x: x, y: y),
      _p(ms: atMs + holdMs + 16, clicked: false, x: x, y: y),
    ];

void main() {
  const detector = AutoZoomDetector();
  const videoSize = Size(1196, 750);
  const videoDuration = Duration(seconds: 30);

  // Multi-monitor recordings put clicks on another display, recorded as
  // out-of-video-bounds (often negative) coordinates. The detector must
  // NOT create a zoom for those — clamping them in-bounds zooms to a spot
  // where nothing happened.
  test('off-screen negative click does not create a zoom region', () {
    final cursor = _rec(_clickAt(atMs: 2479, x: -1348, y: 263));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('click past the right/bottom edge does not create a zoom region', () {
    final cursor = _rec(_clickAt(atMs: 2479, x: 1500, y: 900));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('an in-bounds click still creates exactly one zoom region', () {
    final cursor = _rec(_clickAt(atMs: 4096, x: 428, y: 382));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
  });

  test('off-screen and on-screen clicks: only the on-screen one yields a zoom',
      () {
    final cursor = _rec([
      ..._clickAt(atMs: 2479, x: -1348, y: 263), // off-screen
      ..._clickAt(atMs: 5000, x: 600, y: 375), // on-screen
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.rect.center.dx, closeTo(600, 1));
  });
}
