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

  test('motionBlurIntensity > 0 + velocity > 0 → N drawImage calls', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: const Offset(2000, 0),
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    expect(drawImages.length, 40,
        reason: 'slider=1, max speed → 40 stamps via pre-baked drawImage.');
  });

  test('motionBlurIntensity > 0 + velocity below threshold → 1 drawImage stamp '
       '(no path divergence vs the no-blur direct paint)', () {
    // Below the activation threshold (30 px/s) samples collapse to
    // count==1, but intensity > 0 must still route through the
    // pre-bake path so that smoothed velocity passing through the
    // threshold doesn't cause a visible toggle between "no shader,
    // sharp cursor" and "shader, blurred cursor". On the multi-stamp
    // fallback this manifests as exactly one drawImage call (the
    // head stamp), not zero.
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: const Offset(10, 0), // < 30 px/s threshold
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final drawImages = canvas.calls.where((c) => c.startsWith('drawImage'));
    expect(drawImages.length, 1);
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
