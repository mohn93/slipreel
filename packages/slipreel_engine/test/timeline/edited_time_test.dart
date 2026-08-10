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
}) => ClipSlice(
  cutStart: Duration(seconds: cs),
  cutEnd: Duration(seconds: ce),
  trimStart: ts == null ? null : Duration(seconds: ts),
  trimEnd: te == null ? null : Duration(seconds: te),
  playbackSpeed: speed,
);

Duration _s(int s) => Duration(seconds: s);
Duration _ms(int ms) => Duration(milliseconds: ms);

class _CountingSourceOrderedClipList extends SourceOrderedClipList {
  _CountingSourceOrderedClipList(super.clips);

  int reads = 0;

  @override
  ClipSlice operator [](int index) {
    reads++;
    return super[index];
  }
}

void main() {
  group('editedProgressAtSource', () {
    // Export progress regression: the numerator counted frames fed to
    // ffmpeg at SOURCE cadence while the denominator was the EDITED
    // duration, so any leading trim, mid-timeline gap, or speed != 1
    // pinned the bar at 100% early. Progress must be the fraction of
    // the edited output completed at a given source position.
    test('untrimmed 1x slice: source midpoint -> 0.5', () {
      final clips = [_slice(cs: 0, ce: 10)];
      expect(editedProgressAtSource(clips, _s(5)), closeTo(0.5, 1e-9));
    });

    test('leading trim: pre-trim source time reports 0, not overshoot', () {
      final clips = [_slice(cs: 0, ce: 30, ts: 10, te: 20)];
      expect(editedProgressAtSource(clips, _s(5)), 0.0);
      expect(editedProgressAtSource(clips, _s(10)), 0.0);
      expect(editedProgressAtSource(clips, _s(15)), closeTo(0.5, 1e-9));
      expect(editedProgressAtSource(clips, _s(20)), closeTo(1.0, 1e-9));
    });

    test('2x speed slice: source midpoint is still half the edited output', () {
      final clips = [_slice(cs: 0, ce: 10, speed: 2.0)];
      expect(editedProgressAtSource(clips, _s(5)), closeTo(0.5, 1e-9));
    });

    test('gap between slices: gap frames contribute no progress', () {
      final clips = [
        _slice(cs: 0, ce: 30, ts: 0, te: 5),
        _slice(cs: 0, ce: 30, ts: 10, te: 15),
      ];
      expect(editedProgressAtSource(clips, _s(5)), closeTo(0.5, 1e-9));
      expect(editedProgressAtSource(clips, _s(7)), closeTo(0.5, 1e-9));
      expect(editedProgressAtSource(clips, _s(10)), closeTo(0.5, 1e-9));
      expect(editedProgressAtSource(clips, _s(15)), closeTo(1.0, 1e-9));
    });

    test('past the final trimEnd clamps to 1.0', () {
      final clips = [_slice(cs: 0, ce: 10)];
      expect(editedProgressAtSource(clips, _s(25)), 1.0);
    });

    test('empty clips falls back to source-duration fraction', () {
      expect(
        editedProgressAtSource(const [], _s(5), sourceFallbackTotal: _s(10)),
        closeTo(0.5, 1e-9),
      );
    });

    test('no denominator available -> null (indeterminate bar)', () {
      expect(editedProgressAtSource(const [], _s(5)), isNull);
      expect(
        editedProgressAtSource(
          const [],
          _s(5),
          sourceFallbackTotal: Duration.zero,
        ),
        isNull,
      );
    });
  });

  group('totalEditedDuration', () {
    test('empty -> zero', () {
      expect(totalEditedDuration(const []), Duration.zero);
    });

    test('single untrimmed slice -> its cut span', () {
      expect(totalEditedDuration([_slice(cs: 0, ce: 10)]), _s(10));
    });

    test('single trimmed slice -> trim span only', () {
      expect(totalEditedDuration([_slice(cs: 0, ce: 10, ts: 2, te: 8)]), _s(6));
    });

    test('two adjacent slices, no trimming -> sum', () {
      expect(
        totalEditedDuration([_slice(cs: 0, ce: 5), _slice(cs: 5, ce: 12)]),
        _s(12),
      );
    });

    test(
      'two slices with a gap in source time -> sum of trims, gap is removed',
      () {
        expect(
          totalEditedDuration([_slice(cs: 0, ce: 5), _slice(cs: 8, ce: 12)]),
          _s(9), // 5 + 4
        );
      },
    );
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
      final clips = [_slice(cs: 0, ce: 5), _slice(cs: 8, ce: 12)];
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

    test(
      'source-position inside removed-left-trim collapses to slice start in edited',
      () {
        final clips = [_slice(cs: 0, ce: 10, ts: 3, te: 8)];
        // source 1s is in the trimmed-away left region -> maps to 0 (start of slice in edited).
        expect(sourceToEdited(clips, _s(1)), Duration.zero);
      },
    );

    test('after all slices -> total edited duration', () {
      final clips = [_slice(cs: 0, ce: 5), _slice(cs: 8, ce: 12)];
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
      expect(totalEditedDuration([_slice(cs: 0, ce: 10, speed: 2.0)]), _s(5));
    });

    test('totalEditedDuration doubles at 0.5x speed', () {
      expect(totalEditedDuration([_slice(cs: 0, ce: 10, speed: 0.5)]), _s(20));
    });

    test('totalEditedDuration sums mixed speeds', () {
      final clips = [
        _slice(cs: 0, ce: 10, speed: 2.0), // -> 5s edited
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
        _slice(cs: 0, ce: 10, speed: 2.0), // 5s edited
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

    test('wall lookback traverses contiguous slices at each slice speed', () {
      final clips = [_slice(cs: 0, ce: 1), _slice(cs: 1, ce: 2, speed: 2.0)];

      expect(
        sourceTimeBeforeWallDuration(clips, _ms(1050), _ms(100)),
        _ms(925),
      );
    });

    test('wall lookback stops at a hard source cut', () {
      final clips = [_slice(cs: 0, ce: 1), _slice(cs: 2, ce: 3, speed: 2.0)];

      expect(sourceTimeBeforeWallDuration(clips, _ms(2050), _ms(100)), _s(2));
    });

    test('contiguous run bounds span splits but stop at source gaps', () {
      final clips = [
        _slice(cs: 0, ce: 1),
        _slice(cs: 1, ce: 2),
        _slice(cs: 3, ce: 4),
      ];

      expect(contiguousClipRunBounds(clips, _ms(1500)), (
        start: Duration.zero,
        end: _s(2),
      ));
      expect(contiguousClipRunBounds(clips, _ms(3500)), (
        start: _s(3),
        end: _s(4),
      ));
    });
  });

  group('sourceFrameContributes', () {
    // Slice-aware export skip: a source frame only needs full composition
    // when ffmpeg's per-slice trim can keep it. The margin absorbs
    // frame-boundary rounding between our index/fps timestamps and the
    // filter graph's fractional trim seconds — a blanked frame that ffmpeg
    // unexpectedly kept would flash black in the output.
    final margin = _ms(40); // one frame period at 25fps

    test('empty clip list: every frame contributes', () {
      expect(sourceFrameContributes([], _s(3), margin: margin), isTrue);
      expect(sourceFrameContributes([], Duration.zero, margin: margin), isTrue);
    });

    test('inside a trim window contributes', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(sourceFrameContributes(clips, _s(5), margin: margin), isTrue);
    });

    test('exactly at trimStart and trimEnd contributes', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(sourceFrameContributes(clips, _s(2), margin: margin), isTrue);
      expect(sourceFrameContributes(clips, _s(8), margin: margin), isTrue);
    });

    test('within margin outside the window still contributes', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(
        sourceFrameContributes(clips, _s(2) - _ms(40), margin: margin),
        isTrue,
      );
      expect(
        sourceFrameContributes(clips, _s(8) + _ms(40), margin: margin),
        isTrue,
      );
    });

    test('beyond margin in a leading trim does not contribute', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(
        sourceFrameContributes(clips, _s(2) - _ms(41), margin: margin),
        isFalse,
      );
      expect(
        sourceFrameContributes(clips, Duration.zero, margin: margin),
        isFalse,
      );
    });

    test('beyond margin after the last trimEnd does not contribute', () {
      final clips = [_slice(cs: 0, ce: 10, ts: 2, te: 8)];
      expect(
        sourceFrameContributes(clips, _s(8) + _ms(41), margin: margin),
        isFalse,
      );
      expect(sourceFrameContributes(clips, _s(10), margin: margin), isFalse);
    });

    test('mid-timeline gap between two slices does not contribute', () {
      final clips = [
        _slice(cs: 0, ce: 3, ts: 0, te: 3),
        _slice(cs: 3, ce: 10, ts: 6, te: 9),
      ];
      expect(sourceFrameContributes(clips, _ms(4500), margin: margin), isFalse);
      // Both edges of the gap stay live.
      expect(sourceFrameContributes(clips, _s(3), margin: margin), isTrue);
      expect(sourceFrameContributes(clips, _s(6), margin: margin), isTrue);
    });
  });

  test(
    'indexed timeline lookups match the linear reference on many slices',
    () {
      final clips = <ClipSlice>[
        for (var i = 0; i < 256; i++)
          ClipSlice(
            cutStart: Duration(milliseconds: i * 1200),
            cutEnd: Duration(milliseconds: i * 1200 + 1000),
            trimStart: Duration(milliseconds: i * 1200 + 100),
            trimEnd: Duration(milliseconds: i * 1200 + 900),
            playbackSpeed: [0.5, 1.0, 1.5, 2.0][i % 4],
          ),
      ];

      Duration linearSourceToEdited(Duration position) {
        var edited = Duration.zero;
        for (final clip in clips) {
          if (position < clip.trimStart) return edited;
          if (position <= clip.trimEnd) {
            return edited +
                Duration(
                  microseconds:
                      ((position - clip.trimStart).inMicroseconds /
                              clip.playbackSpeed)
                          .round(),
                );
          }
          edited += clip.editedLength;
        }
        return edited;
      }

      int linearContaining(Duration position) {
        for (var i = 0; i < clips.length; i++) {
          if (position >= clips[i].trimStart && position < clips[i].trimEnd) {
            return i;
          }
        }
        return -1;
      }

      for (var ms = 0; ms <= 307000; ms += 37) {
        final position = Duration(milliseconds: ms);
        expect(sourceToEdited(clips, position), linearSourceToEdited(position));
        expect(
          clipSliceIndexContaining(clips, position),
          linearContaining(position),
        );
      }
    },
  );

  test('mutable list changes never reuse a stale prepared timeline', () {
    final clips = <ClipSlice>[_slice(cs: 0, ce: 1)];
    expect(totalEditedDuration(clips), _s(1));
    expect(sourceToEdited(clips, _ms(500)), _ms(500));

    clips.add(_slice(cs: 1, ce: 3));
    expect(totalEditedDuration(clips), _s(3));
    expect(sourceToEdited(clips, _ms(2500)), _ms(2500));
    expect(contiguousClipRunBounds(clips, _ms(2500)), (
      start: Duration.zero,
      end: _s(3),
    ));

    clips.removeAt(0);
    expect(totalEditedDuration(clips), _s(2));
    expect(sourceToEdited(clips, _ms(2500)), _ms(1500));
  });

  test('editedToSource uses the prepared index instead of a linear scan', () {
    final clips = _CountingSourceOrderedClipList([
      for (var i = 0; i < 1024; i++)
        ClipSlice(
          cutStart: Duration(seconds: i),
          cutEnd: Duration(seconds: i + 1),
        ),
    ]);

    // Warm and memoize the immutable-list index, then measure only the lookup.
    expect(totalEditedDuration(clips), const Duration(seconds: 1024));
    clips.reads = 0;

    expect(
      editedToSource(clips, const Duration(milliseconds: 1023500)),
      const Duration(milliseconds: 1023500),
    );
    expect(
      clips.reads,
      lessThan(20),
      reason: 'a 1024-clip lookup should require logarithmic clip reads',
    );
  });
}
