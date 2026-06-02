import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

// Helpers for terser fixtures.
ClipSlice _slice({
  int cs = 0,
  int ce = 10,
  int? ts,
  int? te,
  double speed = 1.0,
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
      playbackSpeed: speed,
    );

Duration _s(int s) => Duration(seconds: s);

void main() {
  group('totalEditedDuration', () {
    test('empty -> zero', () {
      expect(totalEditedDuration(const []), Duration.zero);
    });

    test('single untrimmed slice -> its cut span', () {
      expect(totalEditedDuration([_slice(cs: 0, ce: 10)]), _s(10));
    });

    test('single trimmed slice -> trim span only', () {
      expect(
        totalEditedDuration([_slice(cs: 0, ce: 10, ts: 2, te: 8)]),
        _s(6),
      );
    });

    test('two adjacent slices, no trimming -> sum', () {
      expect(
        totalEditedDuration([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12),
        ]),
        _s(12),
      );
    });

    test('two slices with a gap in source time -> sum of trims, gap is removed', () {
      expect(
        totalEditedDuration([
          _slice(cs: 0, ce: 5),
          _slice(cs: 8, ce: 12),
        ]),
        _s(9), // 5 + 4
      );
    });
  });

  group('editedToSource', () {
    test('empty clips -> zero', () {
      expect(editedToSource(const [], _s(3)), Duration.zero);
    });

    test('inside single slice -> trimStart + offset', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(editedToSource(clips, _s(0)), _s(2));
      expect(editedToSource(clips, _s(3)), _s(5));
      expect(editedToSource(clips, _s(6)), _s(8));
    });

    test('crosses slice boundary -> jumps over the gap', () {
      // Slice A spans source [0,5], slice B spans source [8,12].
      // Edited time 5s == end of A. Edited time 5.000001s is inside B
      // at source 8.000001s. We test the exact-boundary case as A's end.
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 8, ce: 12),
      ];
      expect(editedToSource(clips, _s(5)), _s(5)); // end of A
      expect(editedToSource(clips, _s(6)), _s(9)); // 1s into B
    });

    test('beyond final edited time -> final trimEnd', () {
      final clips = [_slice(cs: 0, ce: 5)];
      expect(editedToSource(clips, _s(99)), _s(5));
    });
  });

  group('sourceToEdited', () {
    test('empty -> zero', () {
      expect(sourceToEdited(const [], _s(3)), Duration.zero);
    });

    test('before any slice -> 0', () {
      final clips = [_slice(cs: 2, ce: 10)];
      expect(sourceToEdited(clips, _s(0)), Duration.zero);
    });

    test('inside untrimmed single slice -> offset from cutStart', () {
      final clips = [_slice(cs: 0, ce: 10)];
      expect(sourceToEdited(clips, _s(0)), Duration.zero);
      expect(sourceToEdited(clips, _s(5)), _s(5));
    });

    test('inside trimmed single slice -> offset from trimStart', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(sourceToEdited(clips, _s(2)), Duration.zero);
      expect(sourceToEdited(clips, _s(5)), _s(3));
    });

    test('source-position inside removed-left-trim collapses to slice start in edited', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 3, te: 8)];
      // source 1s is in the trimmed-away left region -> maps to 0 (start of slice in edited).
      expect(sourceToEdited(clips, _s(1)), Duration.zero);
    });

    test('after all slices -> total edited duration', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 8, ce: 12),
      ];
      expect(sourceToEdited(clips, _s(20)), _s(9));
    });
  });

  group('nextPlayPosition', () {
    test('empty -> null', () {
      expect(nextPlayPosition(const [], _s(3)), null);
    });

    test('before first slice -> first slice trimStart', () {
      final clips = [_slice(cs: 2, ce: 10, ts: 3, te: 8)];
      expect(nextPlayPosition(clips, _s(0)), _s(3));
    });

    test('inside a slice trim range -> same position', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(nextPlayPosition(clips, _s(5)), _s(5));
    });

    test('at trimEnd -> next slice trimStart', () {
      final clips = [
        _slice(cs: 0, ce: 5, ts: 0, te: 5),
        _slice(cs: 8, ce: 12, ts: 8, te: 12),
      ];
      expect(nextPlayPosition(clips, _s(5)), _s(8));
    });

    test('past all slices -> null', () {
      final clips = [_slice(cs: 0, ce: 5)];
      expect(nextPlayPosition(clips, _s(7)), null);
    });
  });

  group('speed-aware helpers', () {
    test('totalEditedDuration halves at 2x speed', () {
      expect(
        totalEditedDuration([_slice(cs: 0, ce: 10, speed: 2.0)]),
        _s(5),
      );
    });

    test('totalEditedDuration doubles at 0.5x speed', () {
      expect(
        totalEditedDuration([_slice(cs: 0, ce: 10, speed: 0.5)]),
        _s(20),
      );
    });

    test('totalEditedDuration sums mixed speeds', () {
      final clips = [
        _slice(cs: 0, ce: 10, speed: 2.0),  // -> 5s edited
        _slice(cs: 10, ce: 16, speed: 0.5), // -> 12s edited
      ];
      expect(totalEditedDuration(clips), _s(17));
    });

    test('editedToSource scales offset by playbackSpeed', () {
      final clips = [_slice(cs: 0, ce: 10, speed: 2.0)]; // 5s edited
      // Edited 2s into the slice = source 4s (2 × 2.0).
      expect(editedToSource(clips, _s(2)), _s(4));
      // Edited at end (5s) = source trimEnd (10s).
      expect(editedToSource(clips, _s(5)), _s(10));
    });

    test('editedToSource walks across speed-adjusted boundary', () {
      final clips = [
        _slice(cs: 0, ce: 10, speed: 2.0),  // 5s edited
        _slice(cs: 10, ce: 14, speed: 1.0), // 4s edited
      ];
      // Edited 6s = 1s into slice 1 at 1x = source 11s.
      expect(editedToSource(clips, _s(6)), _s(11));
    });

    test('sourceToEdited compresses source offset by speed', () {
      final clips = [_slice(cs: 0, ce: 10, speed: 2.0)]; // 5s edited
      // Source 4s -> edited 2s.
      expect(sourceToEdited(clips, _s(4)), _s(2));
      expect(sourceToEdited(clips, _s(10)), _s(5));
    });

    test('sourceToEdited round-trips through editedToSource at 1.5x', () {
      final clips = [_slice(cs: 0, ce: 9, speed: 1.5)]; // 6s edited
      final s = editedToSource(clips, _s(3));
      expect(sourceToEdited(clips, s), _s(3));
    });
  });
}
