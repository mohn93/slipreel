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

  test('motionBlurIntensity 0 → no saveLayer/restore wrapping (single direct paint)', () {
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
    final stampOpens = canvas.calls.where((c) => c.startsWith('saveLayer'));
    expect(stampOpens, isEmpty,
        reason: 'No blur ⇒ painter draws directly without a stamp envelope.');
  });

  test('motionBlurIntensity > 0 + velocity > 0 → N saveLayer/restore pairs', () {
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
    final saveLayers = canvas.calls.where((c) => c.startsWith('saveLayer'));
    final restores = canvas.calls.where((c) => c == 'restore');
    expect(saveLayers.length, 12,
        reason: 'slider=1, max speed → 12 stamps.');
    expect(restores.length, 12);
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
