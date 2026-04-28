import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'dart:ui';

void main() {
  group('cursorAt', () {
    test('returns null for empty recording', () {
      final rec = CursorRecording();
      expect(cursorAt(rec, const Duration(seconds: 1)), isNull);
    });

    test('returns exact match when one exists', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 10, y: 20, timestampMicros: 1000000, isClicked: false));
      final pos = cursorAt(rec, const Duration(seconds: 1));
      expect(pos, isNotNull);
      expect(pos!.x, 10);
      expect(pos.y, 20);
    });

    test('interpolates between samples', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 0, y: 0, timestampMicros: 0, isClicked: false))
        ..addPosition(const CursorPosition(
            x: 100, y: 200, timestampMicros: 1000000, isClicked: false));
      final pos = cursorAt(rec, const Duration(milliseconds: 500));
      expect(pos!.x, closeTo(50, 0.1));
      expect(pos.y, closeTo(100, 0.1));
    });

    test('preserves isClicked true if either neighbor is clicked', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 0, y: 0, timestampMicros: 0, isClicked: false))
        ..addPosition(const CursorPosition(
            x: 10, y: 10, timestampMicros: 1000000, isClicked: true));
      final pos = cursorAt(rec, const Duration(milliseconds: 500));
      expect(pos!.isClicked, isTrue);
    });

    test('returns first position when queried before all samples', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 5, y: 5, timestampMicros: 500000, isClicked: false));
      final pos = cursorAt(rec, Duration.zero);
      expect(pos?.x, 5);
      expect(pos?.y, 5);
    });

    test('returns last position when queried after all samples', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 5, y: 5, timestampMicros: 0, isClicked: false));
      final pos = cursorAt(rec, const Duration(seconds: 60));
      expect(pos?.x, 5);
      expect(pos?.y, 5);
    });
  });

  group('screenToVideoSpace', () {
    test('identity when sizes match', () {
      const screenPos = Offset(100, 200);
      final result = screenToVideoSpace(
        screenPos: screenPos,
        screenSize: const Size(1920, 1080),
        videoSize: const Size(1920, 1080),
      );
      expect(result, const Offset(100, 200));
    });

    test('scales when video is downscaled', () {
      const screenPos = Offset(960, 540);
      final result = screenToVideoSpace(
        screenPos: screenPos,
        screenSize: const Size(1920, 1080),
        videoSize: const Size(960, 540),
      );
      expect(result.dx, closeTo(480, 0.1));
      expect(result.dy, closeTo(270, 0.1));
    });
  });
}
