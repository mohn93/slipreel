import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/cursor_interaction.dart';
import 'package:slipreel_engine/editor/interaction_classifier.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

CursorPosition _p({
  required int ms,
  required bool clicked,
  double x = 100,
  double y = 100,
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

/// A press→release gesture. Emits a pre-press sample (so the state
/// lookback window has something to read), the press, an optional mid
/// sample, and the release.
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
    _p(
      ms: atMs + durationMs,
      clicked: true,
      x: endX,
      y: endY,
      state: state,
    ),
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
  const classifier = InteractionClassifier();
  const videoSize = Size(1920, 1080);
  // diagonal = sqrt(1920^2 + 1080^2) ≈ 2202.9
  // drag displacement threshold = 0.02 * 2202.9 ≈ 44.06 px

  test('empty recording yields no interactions', () {
    expect(classifier.classify(CursorRecording(), videoSize), isEmpty);
  });

  test('stationary arrow click is InteractionKind.click', () {
    final out = classifier.classify(
      _rec(_gesture(atMs: 1000, fromX: 500, fromY: 400)),
      videoSize,
    );
    expect(out, hasLength(1));
    expect(out.single.kind, InteractionKind.click);
    expect(out.single.anchor, const Offset(500, 400));
    expect(out.single.start, const Duration(milliseconds: 1000));
  });

  test('stationary iBeam click is InteractionKind.textEntry', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.textEntry);
  });

  test('long arrow drag is InteractionKind.drag', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('horizontal iBeam drag is InteractionKind.textSelection', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 400,
        fromY: 400,
        toX: 900,
        toY: 410,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.textSelection);
  });

  test('vertical iBeam drag is drag, not textSelection', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 400,
        fromY: 300,
        toX: 410,
        toY: 800,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('displacement below threshold stays a click', () {
    // 40px < 44.06px threshold
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 540,
        toY: 400,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.click);
  });

  test('displacement above threshold becomes a drag', () {
    // 50px > 44.06px threshold
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 550,
        toY: 400,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('dwell below 200ms stays a click even when displaced', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 199,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.click);
  });

  test('dwell at exactly 200ms qualifies as a drag', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 200,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('axis ratio below 1.8 is drag, above is textSelection', () {
    // Brackets the 1.8 threshold tightly from both sides. The predicate is
    // `dx > horizontalAxisRatio * dy` (strict greater-than): the lower case
    // pins drift strictly below 1.7 (not caught at exactly 1.7), and the
    // upper case pins drift strictly above 1.8.
    // dx = 340, dy = 200 -> ratio 1.7, just below threshold
    final shallow = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 300,
        fromY: 300,
        toX: 640,
        toY: 500,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(shallow.single.kind, InteractionKind.drag);

    // dx = 380, dy = 200 -> ratio 1.9, just above threshold
    final flat = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 300,
        fromY: 300,
        toX: 680,
        toY: 500,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(flat.single.kind, InteractionKind.textSelection);
  });

  test('sweptBounds covers the whole gesture path', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.sweptBounds, const Rect.fromLTRB(500, 400, 900, 700));
  });

  test('stationary click has a zero-size sweptBounds at the anchor', () {
    final out = classifier.classify(
      _rec(_gesture(atMs: 1000, fromX: 500, fromY: 400)),
      videoSize,
    );
    expect(out.single.sweptBounds, Rect.zero.shift(const Offset(500, 400)));
  });

  test('unterminated press releases at the last sample', () {
    final out = classifier.classify(
      _rec([
        _p(ms: 0, clicked: false, x: 500, y: 400),
        _p(ms: 100, clicked: true, x: 500, y: 400),
        _p(ms: 600, clicked: true, x: 900, y: 700),
      ]),
      videoSize,
    );
    expect(out, hasLength(1));
    expect(out.single.end, const Duration(milliseconds: 600));
    expect(out.single.kind, InteractionKind.drag);
  });

  test('state is read from before the press, not at it', () {
    // Cursor is iBeam while hovering, then the OS swaps to arrow at the
    // instant of the press. We must classify on the pre-press state.
    final out = classifier.classify(
      _rec([
        _p(ms: 970, clicked: false, x: 500, y: 400, state: CursorState.iBeam),
        _p(ms: 985, clicked: false, x: 500, y: 400, state: CursorState.iBeam),
        _p(ms: 1000, clicked: true, x: 500, y: 400, state: CursorState.arrow),
        _p(ms: 1050, clicked: true, x: 500, y: 400, state: CursorState.arrow),
        _p(ms: 1066, clicked: false, x: 500, y: 400, state: CursorState.arrow),
      ]),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.textEntry);
  });

  test('press-time state loses a tie against the pre-press sample', () {
    // Exactly one pre-press sample inside the 50ms window, versus the
    // press sample itself. With the press sample excluded the vote is
    // unanimous for iBeam. If the press sample were counted the vote
    // would tie and the contaminated arrow state would win, which is
    // precisely the OS-swaps-cursor-on-click case the lookback exists
    // to defend against.
    final out = classifier.classify(
      _rec([
        _p(ms: 960, clicked: false, x: 500, y: 400, state: CursorState.iBeam),
        _p(ms: 1000, clicked: true, x: 500, y: 400, state: CursorState.arrow),
        _p(ms: 1050, clicked: true, x: 500, y: 400, state: CursorState.arrow),
        _p(ms: 1066, clicked: false, x: 500, y: 400, state: CursorState.arrow),
      ]),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.textEntry);
  });

  test('legacy recording with no cursor state degrades to click and drag', () {
    // Recordings predating the state field load every sample as
    // CursorState.arrow, so textEntry and textSelection can never fire.
    // The second gesture here is horizontal enough to be a text
    // selection if the pointer had read iBeam — it must come out as a
    // plain drag instead, not fail.
    final out = classifier.classify(
      _rec([
        ..._gesture(atMs: 1000, fromX: 500, fromY: 400),
        ..._gesture(
          atMs: 3000,
          fromX: 400,
          fromY: 400,
          toX: 900,
          toY: 410,
          durationMs: 400,
        ),
      ]),
      videoSize,
    );
    expect(
      out.map((i) => i.kind).toList(),
      [InteractionKind.click, InteractionKind.drag],
    );
  });

  test('two separate gestures yield two interactions', () {
    final out = classifier.classify(
      _rec([
        ..._gesture(atMs: 1000, fromX: 300, fromY: 300),
        ..._gesture(atMs: 3000, fromX: 800, fromY: 600),
      ]),
      videoSize,
    );
    expect(out, hasLength(2));
    expect(out[0].anchor, const Offset(300, 300));
    expect(out[1].anchor, const Offset(800, 600));
  });

  test('a press already held at the first sample is still captured', () {
    // Recording starts mid-press. Seeding prevClicked from samples.first
    // meant no rising edge was ever seen, so the release failed the
    // pressIndex guard and the gesture vanished silently.
    final out = classifier.classify(
      _rec([
        _p(ms: 0, clicked: true, x: 640, y: 480),
        _p(ms: 50, clicked: true, x: 640, y: 480),
        _p(ms: 66, clicked: false, x: 640, y: 480),
      ]),
      videoSize,
    );
    expect(out, hasLength(1));
    expect(out.single.kind, InteractionKind.click);
    expect(out.single.anchor, const Offset(640, 480));
    expect(out.single.start, Duration.zero);
    expect(out.single.end, const Duration(milliseconds: 50));
    // pressIndex == 0 has no lookback window; state falls back to the
    // press sample's own state.
    expect(out.single.state, CursorState.arrow);
  });

  test('duplicate timestamps do not stall the state lookback', () {
    // The backward state walk's only natural exit is the
    // `timestampMicros < windowStart` break, which assumes timestamps
    // strictly decrease going backwards. Duplicates (or out-of-order data —
    // nothing in the load path validates monotonicity) never trip it, so the
    // walk ran to index 0 for every press: measurably O(n²). A hard cap on
    // samples examined bounds it without changing well-formed results.
    const pressMs = 1000;
    CursorPosition sample({required int ms, required bool clicked}) => _p(
          ms: ms,
          clicked: clicked,
          x: 500,
          y: 400,
          state: CursorState.iBeam,
        );

    // Every sample stamped at the same instant, alternating pressed and
    // released. Each press sits inside every earlier sample's lookback
    // window, so the walk never breaks and its cost grows with the press's
    // index — quadratic across the 10000 presses. Measured unbounded:
    // 162 / 593 / 2598 / 14316 ms at n = 5k / 10k / 20k / 40k. Bounded, the
    // same inputs run in 16 / 13 / 24 / 34 ms.
    const n = 20000;
    final degenerate = _rec([
      for (var i = 0; i < n; i++) sample(ms: pressMs, clicked: i.isOdd),
    ]);
    final wellFormed = _rec([
      sample(ms: pressMs - 16, clicked: false),
      sample(ms: pressMs, clicked: true),
      sample(ms: pressMs + 16, clicked: false),
    ]);

    final sw = Stopwatch()..start();
    final out = classifier.classify(degenerate, videoSize);
    sw.stop();

    final reference = classifier.classify(wellFormed, videoSize).single;
    expect(out, hasLength(n ~/ 2));
    // Same classification the well-formed equivalent yields: the cap only
    // shortens the modal-state sample, it does not change the answer.
    expect(out.every((i) => i.kind == reference.kind), isTrue);
    expect(out.every((i) => i.state == reference.state), isTrue);
    expect(out.every((i) => i.anchor == reference.anchor), isTrue);
    expect(out.every((i) => i.sweptBounds == reference.sweptBounds), isTrue);

    // Generous: the bounded walk runs in ~25 ms here, the unbounded one in
    // ~2.6 s. The 40x margin is for slow CI, not room for a regression to
    // hide in — a quadratic walk over 20k samples cannot fit under this.
    expect(
      sw.elapsedMilliseconds,
      lessThan(1000),
      reason: 'the state lookback must not degrade to O(n^2)',
    );
  });

  test('a held-from-start press that travels is still a drag', () {
    final out = classifier.classify(
      _rec([
        _p(ms: 0, clicked: true, x: 300, y: 400, state: CursorState.iBeam),
        _p(ms: 300, clicked: true, x: 800, y: 410, state: CursorState.iBeam),
        _p(ms: 316, clicked: false, x: 800, y: 410, state: CursorState.iBeam),
      ]),
      videoSize,
    );
    expect(out, hasLength(1));
    expect(out.single.kind, InteractionKind.textSelection);
    expect(out.single.anchor, const Offset(300, 400));
  });
}
