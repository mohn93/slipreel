import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';

void main() {
  ClipSlice slice(int startMs, int endMs) => ClipSlice(
        cutStart: Duration(milliseconds: startMs),
        cutEnd: Duration(milliseconds: endMs),
      );

  group('decideCut', () {
    final clips = [slice(0, 10000)];

    test('snap on, within radius -> snaps to click, snapTarget set', () {
      final d = decideCut(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        clickTimesSource: const [Duration(milliseconds: 5000)],
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(d.time, const Duration(milliseconds: 5000));
      expect(d.snapTarget, const Duration(milliseconds: 5000));
    });

    test('snap on, outside radius -> raw playhead, snapTarget null', () {
      final d = decideCut(
        playheadEdited: const Duration(milliseconds: 5200),
        clips: clips,
        clickTimesSource: const [Duration(milliseconds: 5000)],
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(d.time, const Duration(milliseconds: 5200));
      expect(d.snapTarget, isNull);
    });

    test('snap off (global) -> raw playhead, snapTarget null', () {
      final d = decideCut(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        clickTimesSource: const [Duration(milliseconds: 5000)],
        zoomEdgesSource: const [],
        snapEnabled: false,
        overrideSnap: false,
      );
      expect(d.time, const Duration(milliseconds: 5050));
      expect(d.snapTarget, isNull);
    });

    test('overrideSnap (Option) -> raw playhead, snapTarget null', () {
      final d = decideCut(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        clickTimesSource: const [Duration(milliseconds: 5000)],
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: true,
      );
      expect(d.time, const Duration(milliseconds: 5050));
      expect(d.snapTarget, isNull);
    });

    test('zoom edge wins when closer than click', () {
      final d = decideCut(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        clickTimesSource: const [Duration(milliseconds: 5000)],
        zoomEdgesSource: const [Duration(milliseconds: 5040)],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(d.time, const Duration(milliseconds: 5040));
      expect(d.snapTarget, const Duration(milliseconds: 5040));
    });

    test('source-time candidate is mapped through edited-time', () {
      // Two slices: first plays at 2x. A click at source 1100ms
      // (i.e., 100ms into the second slice at 1.0x) maps to edited
      // 600ms (first slice's edited length is 1000/2.0 = 500ms,
      // then +100ms inside the second slice).
      final clipsWithSpeed = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 1000),
          playbackSpeed: 2.0,
        ),
        ClipSlice(
          cutStart: const Duration(milliseconds: 1000),
          cutEnd: const Duration(milliseconds: 3000),
        ),
      ];
      final d = decideCut(
        playheadEdited: const Duration(milliseconds: 580),
        clips: clipsWithSpeed,
        clickTimesSource: const [Duration(milliseconds: 1100)],
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: false,
      );
      // Click at source 1100ms == edited 600ms; playhead at edited
      // 580ms is 20ms away, well inside the 150ms radius.
      expect(d.time, const Duration(milliseconds: 600));
      expect(d.snapTarget, const Duration(milliseconds: 600));
    });
  });
}
