// packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/ui/widgets/cursor_overlay_painter.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _RecordingCanvas implements ui.Canvas {
  final List<String> calls = [];

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    calls.add('saveLayer(alpha=${paint.color.a.toStringAsFixed(3)})');
  }

  @override
  void restore() {
    calls.add('restore');
  }

  @override
  void translate(double dx, double dy) {
    calls.add('translate(${dx.toStringAsFixed(2)}, ${dy.toStringAsFixed(2)})');
  }

  @override
  void drawImage(ui.Image image, Offset offset, Paint paint) {
    calls.add('drawImage(alpha=${paint.color.a.toStringAsFixed(3)})');
  }

  // The motion-blur path uses drawImageRect (not drawImage) so it can
  // map a dpr-scaled bake onto a logical-sized destination. Record it
  // under the same `drawImage(...)` prefix so stamp-count assertions
  // can use a single filter.
  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    calls.add('drawImage(alpha=${paint.color.a.toStringAsFixed(3)})');
  }

  // Unused-by-this-test methods all delegate to noOp. The painter
  // calls drawCircle / drawPath / drawLine etc. via paintCursorWithEffects;
  // we don't care what they do — we only count the stamp envelope.
  @override
  noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) {
      calls.add(invocation.memberName.toString());
    }
    return null;
  }
}

void main() {
  testWidgets('renders without throwing when given a screen position',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 200,
        height: 100,
        child: CustomPaint(
          painter: CursorOverlayPainter(
            cursorRecording: CursorRecording(),
            position: Duration.zero,
            screenPos: const Offset(50, 25),
            videoSize: const Size(200, 100),
            screenSize: const Size(200, 100),
          ),
        ),
      ),
    ));
    expect(find.byType(CustomPaint), findsWidgets);
  });

  test('shouldRepaint true when position changes', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final a = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
    );
    final b = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 200),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
    );
    expect(b.shouldRepaint(a), isTrue);
  });

  test('motionBlurIntensity 0 → no stamp envelope (single direct paint)', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    final saveLayers = canvas.calls.where((c) => c.startsWith('saveLayer'));
    expect(drawImages, isEmpty,
        reason: 'No blur ⇒ painter draws directly, no pre-baked sprite.');
    expect(saveLayers, isEmpty);
  });

  test(
      'motionBlurIntensity > 0 with dense recorded displacement → '
      'full stamp envelope of 40 draws', () {
    // Dense recording at 10 ms cadence (well under the 50 ms gap
    // threshold) with 20 px between samples → 100 px polyline arc
    // length. count = round(100/2) + 1 = 51, capped at maxStamps = 40.
    final rec = CursorRecording();
    for (var i = 0; i <= 5; i++) {
      rec.addPosition(CursorPosition(
        x: i * 20.0,
        y: 0,
        timestampMicros: 50000 + i * 10000,
        isClicked: false,
      ));
    }
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    expect(drawImages.length, 40,
        reason: 'slider=1 + 100 px polyline → 40 stamps via drawImageRect.');
  });

  test(
      'motionBlurIntensity > 0 with stationary cursor across exposure → '
      'direct paint (no bake)', () {
    // Dense recording where every sample is at the same (50, 25)
    // position. Polyline arc length = 0, count = 1, painter
    // short-circuits to direct paint. Important for the "cursor
    // stopped under active zoom" case — stamp/bake path would route
    // through a ui.Image and look stepped under upscaling.
    final rec = CursorRecording();
    for (var i = 0; i <= 5; i++) {
      rec.addPosition(CursorPosition(
        x: 50,
        y: 25,
        timestampMicros: 50000 + i * 10000,
        isClicked: false,
      ));
    }
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    expect(drawImages, isEmpty,
        reason: 'Zero arc length must skip the bake/stamp path entirely.');
  });

  test(
      'motionBlurIntensity > 0 but recording has a sample gap > 50ms → '
      'direct paint (gap-based phantom-path guard)', () {
    // Two samples 100 ms apart with the exposure window (50 ms)
    // landing entirely inside that gap. cursorAt would linearly
    // interpolate between them — fabricating a path through unknown
    // ground — so the painter rejects the trail and draws direct.
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false))
      ..addPosition(const CursorPosition(
          x: 200, y: 0, timestampMicros: 100000, isClicked: false));
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    expect(drawImages, isEmpty,
        reason: 'Wide sample gap must drop the trail to avoid drawing '
            'stamps along a fabricated linearly-interpolated path.');
  });

  test(
      'motionBlurIntensity > 0 with post-idle position warp in window → '
      'direct paint (warp guard)', () {
    // The recording from the user's bug report:
    //   sample[i-2] at t=0    (x, y)
    //   sample[i-1] at t=200  (x, y)   ← 200 ms idle, no motion
    //   sample[i]   at t=224  (x+150, y)   ← 150 px jump in 24 ms
    //
    // The 24 ms gap is below the time-gap threshold (50 ms), so the
    // gap-time check passes the (i-1, i) pair. But cursorAt would
    // happily interpolate across that 150 px warp and drag the trail
    // through phantom positions. The post-idle warp guard recognises
    // the pattern (large displacement preceded by ≥80 ms idle pair)
    // and drops the trail.
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 1000, y: 0, timestampMicros: 0, isClicked: false))
      ..addPosition(const CursorPosition(
          x: 1000, y: 0, timestampMicros: 200000, isClicked: false))
      ..addPosition(const CursorPosition(
          x: 1150, y: 0, timestampMicros: 224000, isClicked: false));
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 250),
      screenPos: const Offset(50, 25),
      videoSize: const Size(2000, 100),
      screenSize: const Size(2000, 100),
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(2000, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    expect(drawImages, isEmpty,
        reason: 'A 150 px jump in a single sample interval right after '
            '200 ms of idle is a system warp, not real motion. The '
            'trail must drop to avoid smearing through fabricated '
            'intermediate positions.');
  });

  test(
      'motionBlurIntensity > 0 with sustained fast motion (no idle before) → '
      'trail draws normally', () {
    // The mirror case: same large per-pair displacement but the
    // preceding pair had a SHORT gap, meaning the cursor was already
    // moving fast — a real flick, not a warp. The trail should draw
    // (40 stamps via the fallback path).
    final rec = CursorRecording();
    // Dense stream at 16.7 ms cadence with 20 px per pair (under the
    // 100 px large-displacement threshold) so the previous pair gap
    // never triggers the post-idle check.
    for (var i = 0; i <= 5; i++) {
      rec.addPosition(CursorPosition(
        x: 1000 + i * 20.0,
        y: 0,
        timestampMicros: 50000 + i * 16700,
        isClicked: false,
      ));
    }
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(2000, 100),
      screenSize: const Size(2000, 100),
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(2000, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    expect(drawImages, isNotEmpty,
        reason: 'Dense fast motion is a real flick — trail must draw.');
  });

  test('shouldRepaint reflects velocity and intensity changes', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final a = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: Offset.zero,
      motionBlurIntensity: 0,
    );
    final b = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: const Offset(500, 0),
      motionBlurIntensity: 0,
    );
    final c = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: Offset.zero,
      motionBlurIntensity: 0.5,
    );
    expect(b.shouldRepaint(a), isTrue, reason: 'velocity changed');
    expect(c.shouldRepaint(a), isTrue, reason: 'intensity changed');
  });
}
