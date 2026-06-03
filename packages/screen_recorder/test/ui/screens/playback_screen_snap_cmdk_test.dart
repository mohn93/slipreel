// packages/screen_recorder/test/ui/screens/playback_screen_snap_cmdk_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';

void main() {
  ClipSlice slice(int startMs, int endMs) => ClipSlice(
        cutStart: Duration(milliseconds: startMs),
        cutEnd: Duration(milliseconds: endMs),
      );

  CursorRecording cursorWithClickAtMs(int ms) {
    final rec = CursorRecording();
    rec.addPosition(const CursorPosition(
      timestampMicros: 0, x: 0, y: 0, isClicked: false,
    ));
    rec.addPosition(CursorPosition(
      timestampMicros: ms * 1000,
      x: 0,
      y: 0,
      isClicked: true,
    ));
    return rec;
  }

  group('decideCutTime', () {
    final clips = [slice(0, 10000)];

    test('snap on, within radius -> snaps to click', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5000));
    });

    test('snap on, outside radius -> raw playhead', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5200),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5200));
    });

    test('snap off (global) -> raw playhead', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: false,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5050));
    });

    test('snap on, overrideSnap (Option) -> raw playhead', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: true,
      );
      expect(cut, const Duration(milliseconds: 5050));
    });

    test('zoom edge wins when closer than click', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [Duration(milliseconds: 5040)],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5040));
    });
  });
}
