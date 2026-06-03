import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/slice_navigation.dart';

void main() {
  ClipSlice slice({
    required int startMs,
    required int endMs,
    double speed = 1.0,
  }) =>
      ClipSlice(
        cutStart: Duration(milliseconds: startMs),
        cutEnd: Duration(milliseconds: endMs),
        playbackSpeed: speed,
      );

  group('nextSliceIndex', () {
    test('empty list returns -1 regardless of direction', () {
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 0, direction: NavDirection.next),
        -1,
      );
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 0, direction: NavDirection.previous),
        -1,
      );
    });

    test('from no-selection, next jumps to slice 0', () {
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 5, direction: NavDirection.next),
        0,
      );
    });

    test('from no-selection, previous jumps to last slice', () {
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 5, direction: NavDirection.previous),
        4,
      );
    });

    test('mid-list advances by one in either direction', () {
      expect(
        nextSliceIndex(currentIndex: 2, sliceCount: 5, direction: NavDirection.next),
        3,
      );
      expect(
        nextSliceIndex(currentIndex: 2, sliceCount: 5, direction: NavDirection.previous),
        1,
      );
    });

    test('at last index, next returns the same index (stop at boundary)', () {
      expect(
        nextSliceIndex(currentIndex: 4, sliceCount: 5, direction: NavDirection.next),
        4,
      );
    });

    test('at first index, previous returns the same index (stop at boundary)', () {
      expect(
        nextSliceIndex(currentIndex: 0, sliceCount: 5, direction: NavDirection.previous),
        0,
      );
    });
  });

  group('sliceEditedStart', () {
    test('index 0 returns Duration.zero', () {
      final clips = [slice(startMs: 0, endMs: 1000)];
      expect(sliceEditedStart(clips, 0), Duration.zero);
    });

    test('sums editedLengths of preceding slices', () {
      final clips = [
        slice(startMs: 0, endMs: 1000),    // editedLength = 1000ms @ 1.0x
        slice(startMs: 1000, endMs: 3000), // editedLength = 2000ms @ 1.0x
        slice(startMs: 3000, endMs: 4000), // editedLength = 1000ms @ 1.0x
      ];
      expect(sliceEditedStart(clips, 0), Duration.zero);
      expect(sliceEditedStart(clips, 1), const Duration(milliseconds: 1000));
      expect(sliceEditedStart(clips, 2), const Duration(milliseconds: 3000));
    });

    test('accounts for per-slice playback speed', () {
      final clips = [
        slice(startMs: 0, endMs: 3000, speed: 1.5),
        slice(startMs: 3000, endMs: 5000),
      ];
      // First slice: 3000ms / 1.5 = 2000ms edited.
      expect(sliceEditedStart(clips, 1), const Duration(milliseconds: 2000));
    });

    test('throws RangeError on out-of-bounds index', () {
      final clips = [slice(startMs: 0, endMs: 1000)];
      expect(() => sliceEditedStart(clips, -1), throwsRangeError);
      expect(() => sliceEditedStart(clips, 1), throwsRangeError);
    });
  });
}
