import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/slice_navigation.dart';

import 'package:screen_recorder/ui/screens/playback/slice_nav_decision.dart';

void main() {
  ClipSlice slice(int aMs, int bMs) => ClipSlice(
        cutStart: Duration(milliseconds: aMs),
        cutEnd: Duration(milliseconds: bMs),
      );

  group('decideSliceNav', () {
    test('returns null on empty clip list (no-op)', () {
      final d = decideSliceNav(
        currentIndex: null,
        clips: const [],
        direction: NavDirection.next,
      );
      expect(d, isNull);
    });

    test('from null selection -> first slice at edited zero', () {
      final clips = [slice(0, 1000), slice(1000, 3000)];
      final d = decideSliceNav(
        currentIndex: null,
        clips: clips,
        direction: NavDirection.next,
      );
      expect(d!.nextIndex, 0);
      expect(d.seekTo, Duration.zero);
      expect(d.isBoundaryNoOp, isFalse);
    });

    test('from null selection -> previous lands on last slice', () {
      final clips = [slice(0, 1000), slice(1000, 3000), slice(3000, 4000)];
      final d = decideSliceNav(
        currentIndex: null,
        clips: clips,
        direction: NavDirection.previous,
      );
      expect(d!.nextIndex, 2);
      expect(d.seekTo, const Duration(milliseconds: 3000));
      expect(d.isBoundaryNoOp, isFalse);
    });

    test('mid-list next advances + seeks to next slice start', () {
      final clips = [slice(0, 1000), slice(1000, 3000), slice(3000, 4000)];
      final d = decideSliceNav(
        currentIndex: 1,
        clips: clips,
        direction: NavDirection.next,
      );
      expect(d!.nextIndex, 2);
      expect(d.seekTo, const Duration(milliseconds: 3000));
      expect(d.isBoundaryNoOp, isFalse);
    });

    test('at last index + next -> boundary no-op', () {
      final clips = [slice(0, 1000), slice(1000, 3000)];
      final d = decideSliceNav(
        currentIndex: 1,
        clips: clips,
        direction: NavDirection.next,
      );
      expect(d!.nextIndex, 1);
      expect(d.isBoundaryNoOp, isTrue);
    });

    test('at first index + previous -> boundary no-op', () {
      final clips = [slice(0, 1000), slice(1000, 3000)];
      final d = decideSliceNav(
        currentIndex: 0,
        clips: clips,
        direction: NavDirection.previous,
      );
      expect(d!.nextIndex, 0);
      expect(d.isBoundaryNoOp, isTrue);
    });
  });
}
