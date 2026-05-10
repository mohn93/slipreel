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

  // The motion-blur fallback uses drawImageRect (not drawImage) so it
  // can map a dpr-scaled bake onto a logical-sized destination. Record
  // it under the same `drawImage(...)` prefix so existing stamp-count
  // assertions keep working.
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
      'motionBlurIntensity > 0 with cursor displacement during exposure → '
      'N drawImage calls', () {
    // The painter computes the trail from cursorAt(T) and
    // cursorAt(T - exposure). Sample at t=100ms; exposure at slider 1
    // is 50ms; lookback hits t=50ms. We seed the recording with a
    // 100-px x-axis displacement between those two timestamps so the
    // trail length is 100 px and the fallback path emits the maximum
    // 40 stamps.
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 50000, isClicked: false))
      ..addPosition(const CursorPosition(
          x: 100, y: 0, timestampMicros: 100000, isClicked: false));
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
        reason: 'slider=1 + 100 px exposure displacement → 40 stamps via '
            'pre-baked drawImage.');
  });

  test(
      'motionBlurIntensity > 0 with no recorded displacement during '
      'exposure → direct paint (no bake)', () {
    // Cursor stationary inside the exposure window: trail vector = 0,
    // count = 1, painter early-returns to direct paint. The bake/
    // shader path would have made the static cursor look pixelated
    // under an active zoom transform, so this short-circuit matters.
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 50, y: 25, timestampMicros: 0, isClicked: false))
      ..addPosition(const CursorPosition(
          x: 50, y: 25, timestampMicros: 100000, isClicked: false));
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
        reason: 'No displacement in the exposure window must skip the '
            'bake/shader path entirely.');
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
