import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/seam_metrics.dart';

ClipSlice _slice({
  required int cs,
  required int ce,
  int? ts,
  int? te,
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

void main() {
  group('hiddenSecondsAtSeam', () {
    test('no trim, adjacent cut boundary -> Duration.zero', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), Duration.zero);
    });

    test('right-side trim on left slice only', () {
      final clips = [
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 1));
    });

    test('left-side trim on right slice only', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10, ts: 6),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 1));
    });

    test('trim on both sides sums', () {
      final clips = [
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10, ts: 7),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 3));
    });

    test('non-adjacent source boundary contributes gap', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 8, ce: 12),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 3));
    });

    test('trim and gap combine', () {
      final clips = [
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 8, ce: 12, ts: 9),
      ];
      // (5-4) + (9-8) + (8-5) = 1 + 1 + 3 = 5
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 5));
    });

    test('out-of-range index returns Duration.zero', () {
      final clips = [_slice(cs: 0, ce: 5)];
      expect(hiddenSecondsAtSeam(clips, 0), Duration.zero);
      expect(hiddenSecondsAtSeam(clips, -1), Duration.zero);
      expect(hiddenSecondsAtSeam(clips, 5), Duration.zero);
    });

    test('empty clips returns Duration.zero', () {
      expect(hiddenSecondsAtSeam(<ClipSlice>[], 0), Duration.zero);
    });
  });
}
