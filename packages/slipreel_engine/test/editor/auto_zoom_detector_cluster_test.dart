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

  test('scattered clicks form separate clusters but their regions merge', () {
    // The two clicks are far enough apart that the union would not fit at
    // 1.25x, so CLUSTERING correctly refuses to group them. Their regions
    // still overlap, though, and an overlap is always below the merge
    // threshold — so the region pass joins them and the camera pans
    // between the two corners rather than cutting out and back in.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 60, y: 60),
      ..._clickAt(atMs: 2800, x: 1860, y: 1020),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 5100));
    expect(out.single.followCursor, isTrue);
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

  test('a cluster splits at the zoom floor, then the regions merge', () {
    // Clicks 1-2 cluster; adding click 3 would make the union 1600x750,
    // which fits at only 1.2x — below the 1.25x floor — so CLUSTERING
    // closes before it. The two resulting regions overlap, so the region
    // pass merges them. The split still happened: without it the union
    // would have framed all three at once instead of the camera panning.
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
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 5100));
    expect(out.single.followCursor, isTrue);
  });

  test('a long click-dense run becomes one following tracking shot', () {
    // Clicks follow, so this cluster follows, so the span ceiling does not
    // apply to it — the ceiling exists to stop a wide ANCHORED union from
    // cropping the whole video, and a following region has no union to
    // frame. The run therefore becomes one sustained tracking shot rather
    // than a series of capped regions.
    //
    // Rewritten from an earlier version that asserted the ceiling split
    // this run. See the "tests that invert deliberately" section of
    // docs/superpowers/specs/2026-08-06-auto-zoom-merge-and-follow-design.md
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

    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
    final maxRegion = detector.leadIn + ZoomShape.maxHold + detector.leadOut;
    expect(
      out.single.duration,
      greaterThan(maxRegion),
      reason: 'a following cluster must not be capped at leadIn + maxHold '
          '+ leadOut',
    );
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

  test('a cluster of clicks follows, because the click shape follows', () {
    // Two clicks close in time and space form one cluster. Since clicks
    // follow as of 2026-08-06, the cluster follows too — the previous
    // "clusters of 2+ are always anchored" rule was decided when clicks
    // did not follow, and keeping it would make two clicks 300ms apart
    // behave differently from two clicks 1500ms apart for no reason the
    // user could observe.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 400),
      ..._clickAt(atMs: 2400, x: 740, y: 420),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
  });

  test('a long click cluster is not capped, because it follows', () {
    // 12 clicks a second apart in a small area. Every gap is under the
    // 1200ms cluster gap and the union stays tiny, so only the span
    // ceiling could split this run — and the ceiling no longer applies to
    // a following cluster. The result is one continuous tracking shot
    // longer than ZoomShape.maxHold.
    final rec = _rec([
      for (var i = 0; i < 12; i++)
        ..._clickAt(atMs: 2000 + i * 1000, x: 800 + i.toDouble(), y: 400),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: const Duration(seconds: 60),
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
    expect(
      out.single.duration,
      greaterThan(const Duration(milliseconds: 7000)),
      reason: 'a following cluster must not be capped at leadIn + maxHold '
          '+ leadOut',
    );
  });

  test('a short textEntry cluster stays anchored', () {
    // textEntry is an anchored shape and this run never reaches the span
    // ceiling, so the cluster keeps the anchored path: fitted union centre
    // and the minClusterZoom floor.
    final rec = _rec([
      for (var i = 0; i < 3; i++)
        ..._clickAt(
          atMs: 2000 + i * 700,
          x: 800,
          y: 400 + i * 30.0,
          state: CursorState.iBeam,
        ),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isFalse);
  });

  test('a long textEntry run comes out following, not anchored', () {
    // Past the span ceiling the cluster closes, but the piece it starts is
    // contiguous with the previous one, so Task 3's merge pass rejoins them
    // — and merged regions follow. The ceiling's real effect is therefore
    // that a long anchored run stops being one wide anchored crop and
    // becomes a tracking shot. Region COUNT is not what it changes.
    final rec = _rec([
      for (var i = 0; i < 12; i++)
        ..._clickAt(
          atMs: 2000 + i * 1000,
          x: 800,
          y: 400 + i.toDouble(),
          state: CursorState.iBeam,
        ),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: const Duration(seconds: 60),
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
  });

  test('regions separated by less than their ramps merge and follow', () {
    // Two clicks far enough apart to be separate clusters (gap well over
    // the 1200ms cluster gap) but whose 2800ms regions still collide.
    // Region 1 = [1500, 4300], region 2 = [3100, 5900]: the regions
    // overlap by 1200ms, which is below the 1000ms of ramps that crossing
    // the seam would cost, so they merge rather than the first being
    // truncated.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 3600, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    expect(r.startTime, const Duration(milliseconds: 1500));
    expect(r.startTime + r.duration, const Duration(milliseconds: 5900));
    expect(r.followCursor, isTrue,
        reason: 'merging exists so the camera can pan across the seam');
  });

  test('regions further apart than their ramps stay separate', () {
    // Same shape, but the second click is late enough that the regions
    // are 1400ms apart — above the 1000ms of ramps — so there is genuine
    // room to return to full frame between them.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 6200, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(2));
    expect(out[0].startTime + out[0].duration,
        const Duration(milliseconds: 4300));
    expect(out[1].startTime, const Duration(milliseconds: 5700));
  });

  test('a merged region follows even when both members were anchored', () {
    // Two iBeam clicks 1600ms apart: above the cluster gap, so they form
    // separate textEntry clusters, and textEntry is an ANCHORED shape.
    // Their regions ([1500,5200] and [3100,6800] at textEntry's 500/2600/600
    // envelope) still overlap, so they merge — and a merged region follows
    // regardless of what its members were, because a seam means two
    // framings to travel between.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450, state: CursorState.iBeam),
      ..._clickAt(atMs: 3600, x: 1100, y: 600, state: CursorState.iBeam),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 6800));
  });

  test('a chain of three collapses into one span, not two', () {
    // Each region is within the merge threshold of the next. Greedy
    // left-to-right merging must carry the accumulated region forward, so
    // the run becomes a single span rather than a merged pair plus a
    // straggler.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 4200, x: 800, y: 500),
      ..._clickAt(atMs: 6400, x: 900, y: 550),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 8700));
  });

  test('a merged region takes the lower zoom, the later exit, and a '
      'matching rect', () {
    // An arrow click (click shape: 1.5x, 500/1800/500) and an iBeam click
    // (textEntry shape: 1.8x, 500/2600/600) 1600ms apart. They are separate
    // clusters, but their regions — [1500,4300] and [3100,6800] — overlap,
    // so they merge.
    //
    // This is the only test where the two members DIFFER in zoom and exit
    // ramp. Without it, swapping the merge's `min` for `max` on zoomLevel,
    // or taking the earlier member's exitDuration, leaves the suite green.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 3600, x: 1100, y: 600, state: CursorState.iBeam),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    expect(r.startTime, const Duration(milliseconds: 1500));
    expect(r.startTime + r.duration, const Duration(milliseconds: 6800));
    // Lower of 1.5 and 1.8 — the widest framing, so the merged span can
    // cover what both members wanted.
    expect(r.zoomLevel, 1.5);
    // The LATER member's exit ramp, not the earlier one's 500ms.
    expect(r.exitDuration, const Duration(milliseconds: 600));
    // Rect dimensions must follow the merged zoom, not either member's.
    expect(r.rect.width, closeTo(1920 / 1.5, 0.001));
    expect(r.rect.height, closeTo(1080 / 1.5, 0.001));
  });

  test('regions exactly at the threshold do not merge', () {
    // Regions run click−500 to click+2300, so clicks 3800ms apart leave a
    // gap of exactly 1000ms — equal to the 500+500 ramp cost. The rule
    // merges on a STRICTLY smaller gap, so this pair stays separate. One
    // millisecond closer and they would merge.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 5800, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(2));
    expect(out[0].startTime + out[0].duration,
        const Duration(milliseconds: 4300));
    expect(out[1].startTime, const Duration(milliseconds: 5300));
  });
}
