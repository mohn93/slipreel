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
    // Brackets the 1.8 threshold tightly from both sides, so a threshold
    // that drifts even 0.1 in either direction fails this test.
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
}
