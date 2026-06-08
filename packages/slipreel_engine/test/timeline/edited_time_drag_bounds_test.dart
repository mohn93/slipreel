// Regression test for M2: dragging a zoom/camera region's edge clamped to a
// wrong (under-shot) end on sped-up or trimmed clips, because the open-ended
// fallback bound (the timeline end, already in EDITED time) was passed through
// sourceToEdited again — double-compressing it.
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

void main() {
  group('editedRegionDragBounds', () {
    // One 2x clip over source [0,10s] -> editedLength 5s, so the timeline
    // (edited) duration the lane receives is 5s.
    final twoXClip = ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(seconds: 10),
      playbackSpeed: 2.0,
    );

    test('open-ended max stays at the timeline (edited) duration on a sped clip',
        () {
      final b = editedRegionDragBounds(
        clips: [twoXClip],
        prevEndSource: null,
        nextStartSource: null,
        timelineDuration: const Duration(seconds: 5),
      );
      // The bug mapped 5s through sourceToEdited -> 2.5s, capping the region to
      // the first half of the timeline. It must stay 5s.
      expect(b.max, const Duration(seconds: 5));
      expect(b.min, Duration.zero);
    });

    test('a source-time neighbor IS mapped into edited time', () {
      final b = editedRegionDragBounds(
        clips: [twoXClip],
        prevEndSource: const Duration(seconds: 4), // source 4s -> edited 2s
        nextStartSource: const Duration(seconds: 6), // source 6s -> edited 3s
        timelineDuration: const Duration(seconds: 5),
      );
      expect(b.min, const Duration(seconds: 2));
      expect(b.max, const Duration(seconds: 3));
    });

    test('trimmed clip: timeline fallback is not re-mapped', () {
      // Trim the first 2s: source [2,10] survives, editedLength 8s, timeline 8s.
      final trimmed = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimStart: const Duration(seconds: 2),
      );
      final b = editedRegionDragBounds(
        clips: [trimmed],
        prevEndSource: null,
        nextStartSource: null,
        timelineDuration: const Duration(seconds: 8),
      );
      // The bug mapped 8s -> 6s edited; correct keeps the full 8s.
      expect(b.max, const Duration(seconds: 8));
    });

    test('empty clips: identity mapping (no clips to compress through)', () {
      final b = editedRegionDragBounds(
        clips: const [],
        prevEndSource: const Duration(seconds: 1),
        nextStartSource: null,
        timelineDuration: const Duration(seconds: 8),
      );
      expect(b.min, const Duration(seconds: 1));
      expect(b.max, const Duration(seconds: 8));
    });
  });
}
