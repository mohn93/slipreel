// packages/slipreel_engine/test/models/cursor_event_index_click_times_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

void main() {
  group('CursorEventIndex.clickTimes', () {
    test('empty recording returns empty list', () {
      final rec = CursorRecording();
      expect(rec.eventIndex.clickTimes, isEmpty);
    });

    test('extracts press rising edges in source-time microseconds order', () {
      final rec = CursorRecording();
      // false -> true at 1s = press
      rec.addPosition(const CursorPosition(
        timestampMicros: 0, x: 0, y: 0, isClicked: false,
      ));
      rec.addPosition(const CursorPosition(
        timestampMicros: 1000000, x: 0, y: 0, isClicked: true,
      ));
      // true -> false at 2s = release (NOT a click time)
      rec.addPosition(const CursorPosition(
        timestampMicros: 2000000, x: 0, y: 0, isClicked: false,
      ));
      // false -> true at 3s = another press
      rec.addPosition(const CursorPosition(
        timestampMicros: 3000000, x: 0, y: 0, isClicked: true,
      ));

      expect(rec.eventIndex.clickTimes, [
        const Duration(seconds: 1),
        const Duration(seconds: 3),
      ]);
    });

    test('returned list is unmodifiable', () {
      final rec = CursorRecording();
      rec.addPosition(const CursorPosition(timestampMicros: 0, x: 0, y: 0, isClicked: false));
      rec.addPosition(const CursorPosition(timestampMicros: 1000000, x: 0, y: 0, isClicked: true));
      expect(
        () => rec.eventIndex.clickTimes.add(Duration.zero),
        throwsUnsupportedError,
      );
    });
  });
}
