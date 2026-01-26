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

    test('should handle division by zero when timestamps are equal', () {
      final recording = CursorRecording();

      // Add two positions with the same timestamp
      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 100));
      recording.addPosition(CursorPosition(x: 100, y: 100, timestampMicros: 100));

      // Should not crash and return one of the positions
      final pos = recording.getPositionAt(100);

      expect(pos, isNotNull);
      expect(pos!.timestampMicros, 100);
    });

    test('should throw error when loading non-existent file', () async {
      expect(
        () => CursorRecording.loadFromFile('non_existent_file.json'),
        throwsA(isA<Exception>()),
      );
    });

    test('should throw error when saving to invalid path', () async {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));

      expect(
        () => recording.saveToFile('/invalid/path/that/does/not/exist/file.json'),
        throwsA(isA<Exception>()),
      );
    });

    test('positions list should be unmodifiable', () {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));

      final positions = recording.positions;

      // Attempting to modify the list should throw
      expect(() => positions.add(CursorPosition(x: 30, y: 40, timestampMicros: 200)),
             throwsUnsupportedError);
    });

    test('binary search should work with large dataset', () {
      final recording = CursorRecording();

      // Add 1000 positions
      for (int i = 0; i < 1000; i++) {
        recording.addPosition(CursorPosition(
          x: i.toDouble(),
          y: i.toDouble(),
          timestampMicros: i * 1000,
        ));
      }

      // Test exact match
      final exact = recording.getPositionAt(500000);
      expect(exact, isNotNull);
      expect(exact!.x, 500);

      // Test interpolation
      final interpolated = recording.getPositionAt(500500);
      expect(interpolated, isNotNull);
      expect(interpolated!.x, closeTo(500.5, 0.1));
    });
  });
}
