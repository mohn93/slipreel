import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/editor/zoom_shape.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

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

List<CursorPosition> _clickAt({
  required int atMs,
  required double x,
  required double y,
  CursorState state = CursorState.arrow,
}) =>
    [
      _p(ms: atMs - 16, clicked: false, x: x, y: y, state: state),
      _p(ms: atMs, clicked: true, x: x, y: y, state: state),
      _p(ms: atMs + 50, clicked: true, x: x, y: y, state: state),
      _p(ms: atMs + 66, clicked: false, x: x, y: y, state: state),
    ];

void main() {
  const detector = AutoZoomDetector();
  const videoSize = Size(1920, 1080);
  const videoDuration = Duration(seconds: 60);

  test('form fill: five nearby clicks merge into one sustained region', () {
    final rec = _rec([
      for (var i = 0; i < 5; i++)
        ..._clickAt(
          atMs: 2000 + i * 800,
          x: 800 + i * 10,
          y: 400 + i * 40,
          state: CursorState.iBeam,
        ),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );

    expect(out, hasLength(1), reason: 'the cluster should be one region');
    final r = out.single;
    // First press 2000ms, minus the 500ms click lead-in.
    expect(r.startTime, const Duration(milliseconds: 1500));
    // Last release is 5200+50 = 5250ms; +500ms lead-out => ends 5750ms.
    expect(r.startTime + r.duration, const Duration(milliseconds: 5750));
    expect(r.followCursor, isFalse, reason: 'clusters stay anchored');
  });

  test('cluster frames every member, not just the first', () {
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 400),
      ..._clickAt(atMs: 2800, x: 900, y: 600),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    // Union of the two zero-size swept boxes centres at (800, 500).
    expect(out.single.rect.center, const Offset(800, 500));
  });

  test('spatially scattered clicks at the same cadence do not merge', () {
    // Same 800ms cadence as the form fill, but far apart: merging them
    // would breach the 1.25x floor, so each stands alone.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 60, y: 60),
      ..._clickAt(atMs: 2800, x: 1860, y: 1020),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    // Two separate clusters; the second region starts inside the first
    // region's span (region 1 = [1500, 4300], region 2 starts 2300), so
    // _dropOverlaps discards it. Assert on startTime rather than the
    // centre: the first click sits outside the non-clamped zone, so its
    // rect centre is pulled to the clamp and says nothing useful.
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
  });

  test('clicks further apart than the cluster gap do not merge', () {
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 800, y: 400),
      ..._clickAt(atMs: 9000, x: 820, y: 420),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(2));
  });

  test('a cluster splits when the next click would breach the zoom floor', () {
    // Three clicks 400ms apart — all within the 1200ms cluster gap, so
    // only the zoom floor can separate them. Clicks 1-2 are close
    // together; adding click 3 would make the union 1600x750, which fits
    // at only min(1920/1600, 1080/750) = 1.2x — below the 1.25x floor —
    // so the cluster closes before it.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 300, y: 300),
      ..._clickAt(atMs: 2400, x: 340, y: 320),
      ..._clickAt(atMs: 2800, x: 1900, y: 1050),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    // The third click starts a second cluster at 2300, inside the first
    // region's span, so _dropOverlaps discards it.
    expect(out, hasLength(1));
    // The surviving region spans clicks 1-2 only: first press 2000, last
    // release 2450 => raw span 450, floored to the click shape's 1800ms
    // hold, total 500 + 1800 + 500 = 2800, so it runs [1500, 4300]. Had
    // all three merged, the raw span would be 2850 — above the floor —
    // and it would end at 5350 instead.
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 4300));
  });

  test('a long click-dense run splits instead of one endless region', () {
    // 40 clicks a second apart in one small area, spanning ~40s. Every
    // 950ms idle gap is under the 1200ms clusterGap and the union stays
    // tiny, so neither the time gate nor the zoom floor can separate
    // them — only the ZoomShape.maxHold span ceiling can. Without it this
    // is a single ~40s "zoom", which is the click-dense case this branch
    // exists to improve.
    final rec = _rec([
      for (var i = 0; i < 40; i++)
        ..._clickAt(
          atMs: 2000 + i * 1000,
          x: 800 + (i % 5) * 8,
          y: 400 + (i % 5) * 8,
        ),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );

    expect(out.length, greaterThan(1),
        reason: 'the run must break into several regions');
    final maxRegion = detector.leadIn + ZoomShape.maxHold + detector.leadOut;
    for (final r in out) {
      expect(r.duration, lessThanOrEqualTo(maxRegion),
          reason: 'region at ${r.startTime} exceeds the span ceiling');
    }
  });

  test('a single interaction still keeps its own follow policy', () {
    // Regression guard: clustering must not flatten a lone drag into an
    // anchored region.
    final rec = _rec([
      _p(ms: 2000 - 16, clicked: false, x: 500, y: 400),
      _p(ms: 2000, clicked: true, x: 500, y: 400),
      _p(ms: 2600, clicked: true, x: 1200, y: 800),
      _p(ms: 2616, clicked: false, x: 1200, y: 800),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out.single.followCursor, isTrue);
  });
}
