import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('CursorRecording', () {
    test('should store and retrieve cursor positions', () {
      final recording = CursorRecording();

      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 0));
      recording.addPosition(CursorPosition(x: 100, y: 100, timestampMicros: 1000));

      expect(recording.count, 2);
    });

    test('should interpolate position between two points', () {
      final recording = CursorRecording();

      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 0));
      recording.addPosition(CursorPosition(x: 100, y: 100, timestampMicros: 1000));

      final pos = recording.getPositionAt(500);

      expect(pos, isNotNull);
      expect(pos!.x, closeTo(50, 0.1));
      expect(pos.y, closeTo(50, 0.1));
    });

    test('should return null for empty recording', () {
      final recording = CursorRecording();

      final pos = recording.getPositionAt(500);

      expect(pos, isNull);
    });

    test('should save and load from file', () async {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));
      recording.addPosition(CursorPosition(x: 30, y: 40, timestampMicros: 200));

      final tempFile = File('test_cursor.json');
      await recording.saveToFile(tempFile.path);

      final loaded = await CursorRecording.loadFromFile(tempFile.path);

      expect(loaded.count, 2);
      expect(loaded.positions[0].x, 10);
      expect(loaded.positions[1].y, 40);

      await tempFile.delete();
    });
  });
}
