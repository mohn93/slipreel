import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/editor/cursor_interaction.dart';
import 'package:slipreel_engine/editor/zoom_shape.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

CursorPosition _p({
  required int ms,
  required bool clicked,
  required double x,
  required double y,
  CursorState state = CursorState.arrow,
}) =>
    CursorPosition(
      x: x,
      y: y,
      timestampMicros: ms * 1000,
      isClicked: clicked,
      state: state,
    );

CursorRecording _rec(List<CursorPosition> positions) {
  final r = CursorRecording();
  for (final p in positions) {
    r.addPosition(p);
  }
  return r;
}

List<CursorPosition> _gesture({
  required int atMs,
  required double fromX,
  required double fromY,
  double? toX,
  double? toY,
  int durationMs = 50,
  CursorState state = CursorState.arrow,
}) {
  final endX = toX ?? fromX;
  final endY = toY ?? fromY;
  return [
    _p(ms: atMs - 16, clicked: false, x: fromX, y: fromY, state: state),
    _p(ms: atMs, clicked: true, x: fromX, y: fromY, state: state),
    _p(ms: atMs + durationMs, clicked: true, x: endX, y: endY, state: state),
    _p(
      ms: atMs + durationMs + 16,
      clicked: false,
      x: endX,
      y: endY,
      state: state,
    ),
  ];
}

void main() {
  const detector = AutoZoomDetector();
  const videoSize = Size(1920, 1080);
  const videoDuration = Duration(seconds: 60);

  test('arrow click keeps the historic 1.5x / 2.8s anchored shape', () {
    final out = detector.detect(
      cursor: _rec(_gesture(atMs: 5000, fromX: 900, fromY: 500)),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    expect(r.zoomLevel, 1.5);
    expect(r.duration, const Duration(milliseconds: 2800));
    expect(r.startTime, const Duration(milliseconds: 4500));
    expect(r.followCursor, isFalse);
    expect(r.rect.center, const Offset(900, 500));
  });

  test('detector click defaults stay in step with the click shape row', () {
    // `_shapeFor` short-circuits InteractionKind.click and rebuilds the
    // shape from the detector's constructor fields, so kZoomShapes' click
    // row is never read in production. Without this test someone could
    // retune that row and see no behaviour change and no failure. Every
    // expectation below is derived from the table, so the two drift apart
    // only over a red suite.
    const gestureMs = 50;
    final shape = kZoomShapes[InteractionKind.click]!;
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 900,
        fromY: 500,
        durationMs: gestureMs,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    expect(r.zoomLevel, shape.zoomLevel);
    expect(r.enterDuration, shape.leadIn);
    expect(r.exitDuration, shape.leadOut);
    expect(
      r.duration,
      shape.leadIn +
          shape.effectiveHold(const Duration(milliseconds: gestureMs)) +
          shape.leadOut,
    );
  });

  test('iBeam click produces a tighter, longer, anchored region', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 900,
        fromY: 500,
        state: CursorState.iBeam,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    final r = out.single;
    expect(r.zoomLevel, 1.8);
    expect(r.duration, const Duration(milliseconds: 3700));
    expect(r.followCursor, isFalse);
  });

  test('drag produces a follow region timed off the gesture', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 500,
        fromY: 400,
        toX: 1200,
        toY: 800,
        durationMs: 1000,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    final r = out.single;
    expect(r.zoomLevel, 1.4);
    expect(r.followCursor, isTrue);
    // leadIn 450 + (gesture 1000 + tail 800) + leadOut 500
    expect(r.duration, const Duration(milliseconds: 2750));
    // Follow regions ride the already-tuned defaults rather than
    // introducing a second tuning surface.
    expect(r.followMode, FollowMode.bounded);
    expect(r.deadzoneRatio, 0.8);
  });

  test('text selection frames the swept range, not the press point', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 400,
        fromY: 500,
        toX: 1000,
        toY: 510,
        durationMs: 500,
        state: CursorState.iBeam,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    final r = out.single;
    // Anchored, so the fitted centre below is load-bearing: an anchored
    // region holds rect.center for its whole life. Were this a follow
    // region the controller would ignore rect.center outright and the
    // fit would be computed and thrown away.
    expect(r.followCursor, isFalse);
    // Swept centre is x=700, not the press point x=400.
    expect(r.rect.center.dx, closeTo(700, 0.001));
  });

  test('a sweep too wide to frame is dropped rather than faked', () {
    // 1720px sweep fits at only 1920/1720 = 1.116x, below the 1.25x floor.
    // A region that shallow renders as a no-op and can shadow a real
    // neighbour via _dropOverlaps, so no region is the right answer.
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 100,
        fromY: 500,
        toX: 1820,
        toY: 510,
        durationMs: 500,
        state: CursorState.iBeam,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('a framable selection caps zoom to fit its sweep', () {
    // 1400px sweep fits at 1920/1400 = 1.371x — below the 1.7x preference,
    // so the cap engages, but above the 1.25x floor so the region survives.
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 260,
        fromY: 500,
        toX: 1660,
        toY: 510,
        durationMs: 500,
        state: CursorState.iBeam,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out.single.zoomLevel, closeTo(1920 / 1400, 0.01));
    expect(out.single.rect.center.dx, closeTo(960, 1.0));
  });

  test('very long drag caps hold at 6s', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 500,
        fromY: 400,
        toX: 1200,
        toY: 800,
        durationMs: 30000,
      )),
      videoSize: videoSize,
      videoDuration: const Duration(seconds: 120),
    );
    // leadIn 450 + capped hold 6000 + leadOut 500
    expect(out.single.duration, const Duration(milliseconds: 6950));
  });

  test('auto-detected regions keep the subtle 3D tilt', () {
    final out = detector.detect(
      cursor: _rec(_gesture(atMs: 5000, fromX: 900, fromY: 500)),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out.single.tilt.style, ZoomTiltStyle.subtle);
  });
}
