import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

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

/// A synthetic isClicked plateau: `down` ms with !clicked, then `hold` ms with
/// clicked, simulating a real mouse-down at the down→up transition we want.
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
  const detector = AutoZoomDetector();
  const videoSize = Size(1920, 1080);
  const videoDuration = Duration(seconds: 30);

  test('empty recording returns no regions', () {
    final out = detector.detect(
      cursor: CursorRecording(),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('recording with positions but zero clicks returns no regions', () {
    final cursor = _rec([
      _p(ms: 0, clicked: false),
      _p(ms: 100, clicked: false),
      _p(ms: 200, clicked: false),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('single isolated click → one region centered on click', () {
    final cursor = _rec(_clickAt(atMs: 5000, x: 800, y: 600));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.first;
    // startTime = 5000 - 500 leadIn = 4500 ms
    expect(r.startTime, const Duration(milliseconds: 4500));
    // duration = 500 + 1800 + 500 = 2800 ms
    expect(r.duration, const Duration(milliseconds: 2800));
    expect(r.zoomLevel, 1.5);
    // rect.center == (800, 600) (no clamping needed for this position)
    expect(r.rect.center, const Offset(800, 600));
    // rect dims = videoSize / zoom
    expect(r.rect.width, closeTo(1920 / 1.5, 0.001));
    expect(r.rect.height, closeTo(1080 / 1.5, 0.001));
    expect(r.followCursor, isFalse);
  });

  test('two clicks 3 s apart → two regions', () {
    // Positions chosen within the non-clamped zone for 1.5× zoom on
    // 1920×1080: cx ∈ [640, 1280], cy ∈ [360, 720].
    final cursor = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 5000, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(2));
    expect(out[0].rect.center, const Offset(700, 450));
    expect(out[1].rect.center, const Offset(1100, 600));
  });

  test('two clicks 0.5 s apart → one merged region spanning both', () {
    // Pre-2026-08 this returned zero regions: the isolation filter
    // dropped both clicks for having a close neighbour, which is why
    // click-dense recordings opened with an empty zoom lane. They now
    // merge into a single sustained region.
    // See docs/superpowers/specs/2026-08-02-auto-zoom-interaction-classifier-design.md
    //
    // Coordinates sit in the non-clamped zone for 1.5× on 1920×1080
    // (cx ∈ [640, 1280], cy ∈ [360, 720]) so the centre assertion below
    // measures the union, not the clamp.
    final cursor = _rec([
      ..._clickAt(atMs: 1000, x: 700, y: 450),
      ..._clickAt(atMs: 1500, x: 740, y: 470),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    // Starts 500ms before the first press and outlives the second click,
    // i.e. it spans the pair rather than being one region plus a drop.
    // First press 1000, last release 1550 => raw span 550, which is below
    // the click shape's 1800ms hold, so the cluster floor raises it to
    // 1800. Total 500 + 1800 + 500 = 2800, so it ends at 3300. Without
    // that floor the merged region would be SHORTER than a lone click's.
    expect(r.startTime, const Duration(milliseconds: 500));
    expect(r.startTime + r.duration, const Duration(milliseconds: 3300));
    // Framed on the union of both clicks (720, 460), not on the first.
    expect(r.rect.center.dx, closeTo(720, 1.0));
    expect(r.rect.center.dy, closeTo(460, 1.0));
  });

  test('two clicks 1.6 s apart → only the first survives (overlap drops second)', () {
    // Both pass the 1.5 s isolation gate. But region1 = [1500, 4300] (start
    // 1500, duration 2800); region2 = [3100, 5900]. They overlap → second
    // dropped.
    // Positions within the non-clamped zone for 1.5× on 1920×1080:
    // cx ∈ [640, 1280], cy ∈ [360, 720].
    final cursor = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 3600, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.first.rect.center, const Offset(700, 450));
  });

  test('click at t=100 ms clamps region start to zero', () {
    final cursor = _rec(_clickAt(atMs: 100, x: 800, y: 600));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.first.startTime, Duration.zero);
  });

  test('click at top-left edge clamps rect center inward', () {
    final cursor = _rec(_clickAt(atMs: 5000, x: 0, y: 0));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final rect = out.first.rect;
    // rect must stay fully inside the video bounds
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(videoSize.width));
    expect(rect.bottom, lessThanOrEqualTo(videoSize.height));
  });

  test('click near end of video clamps duration', () {
    // Video is 30s; click at 29.0s. start = 29000-500 = 28500 ms.
    // raw duration = 2800 → end = 31300 ms which exceeds 30000.
    // Should clamp to 30000-28500 = 1500 ms.
    final cursor = _rec(_clickAt(atMs: 29000, x: 800, y: 600));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.first.startTime, const Duration(milliseconds: 28500));
    expect(out.first.duration, const Duration(milliseconds: 1500));
  });
}
