import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

import 'package:screen_recorder/ui/screens/playback_screen.dart';

ClipSlice _slice({int cs = 0, int ce = 10, int? ts, int? te}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

void main() {
  group('shouldSeekOnTick', () {
    test('inside a slice trim range -> no seek (returns null)', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(shouldSeekOnTick(clips, const Duration(seconds: 5)), null);
    });

    test('at trimEnd with a next slice -> seek to next slice trimStart', () {
      final clips = [
        _slice(cs: 0, ce: 5, ts: 0, te: 5),
        _slice(cs: 8, ce: 12, ts: 8, te: 12),
      ];
      expect(
        shouldSeekOnTick(clips, const Duration(seconds: 5)),
        const Duration(seconds: 8),
      );
    });

    test('past final trimEnd -> seek to final trimEnd (caller pauses)', () {
      final clips = [_slice(cs: 0, ce: 5)];
      expect(
        shouldSeekOnTick(clips, const Duration(seconds: 7)),
        const Duration(seconds: 5),
      );
    });

    test('in a trimmed-away left region -> seek to slice trimStart', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 3)];
      expect(
        shouldSeekOnTick(clips, const Duration(seconds: 1)),
        const Duration(seconds: 3),
      );
    });

    test('empty clips -> null', () {
      expect(shouldSeekOnTick(const [], const Duration(seconds: 1)), null);
    });
  });

  group('seekFromEditedTime', () {
    test('edited 0s with non-zero trimStart -> source = trimStart', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(
        seekFromEditedTime(clips, Duration.zero),
        const Duration(seconds: 2),
      );
    });

    test('edited inside second slice -> source mapped correctly', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 10, ce: 14),
      ];
      // Edited time 6s is 1s into slice 1 (which spans source [10,14]).
      expect(
        seekFromEditedTime(clips, const Duration(seconds: 6)),
        const Duration(seconds: 11),
      );
    });
  });
}
