import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

EditorProjectController _controllerWithClips(List<ClipSlice> clips) {
  final base = EditorProjectState.defaults();
  return EditorProjectController(
    initial: base.copyWith(
      timeline: base.timeline.copyWith(clips: clips),
    ),
  );
}

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
  group('clearSeamTrims', () {
    test('restores both seam trims to their cut bounds', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10, ts: 7),
      ]);
      c.clearSeamTrims(0);
      final clips = c.current.timeline.clips;
      expect(clips[0].trimEnd, const Duration(seconds: 5));
      expect(clips[1].trimStart, const Duration(seconds: 5));
    });

    test('preserves the outer trims (left.trimStart, right.trimEnd)', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, ts: 1, te: 4),
        _slice(cs: 5, ce: 10, ts: 7, te: 9),
      ]);
      c.clearSeamTrims(0);
      final clips = c.current.timeline.clips;
      expect(clips[0].trimStart, const Duration(seconds: 1));
      expect(clips[1].trimEnd, const Duration(seconds: 9));
    });

    test('idempotent when seam already clean', () {
      final initial = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ];
      final c = _controllerWithClips(initial);
      final before = c.current;
      c.clearSeamTrims(0);
      expect(identical(c.current, before), true);
    });

    test('does not change clip count', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10, ts: 7),
        _slice(cs: 10, ce: 15),
      ]);
      c.clearSeamTrims(0);
      expect(c.current.timeline.clips.length, 3);
    });

    test('out-of-range index is a no-op', () {
      final initial = [_slice(cs: 0, ce: 5)];
      final c = _controllerWithClips(initial);
      final before = c.current;
      c.clearSeamTrims(-1);
      c.clearSeamTrims(0);
      c.clearSeamTrims(5);
      expect(identical(c.current, before), true);
    });

    test('non-adjacent source boundary: clears trims but keeps the gap', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 8, ce: 12, ts: 9),
      ]);
      c.clearSeamTrims(0);
      final clips = c.current.timeline.clips;
      expect(clips[0].trimEnd, const Duration(seconds: 5));
      expect(clips[0].cutEnd, const Duration(seconds: 5));
      expect(clips[1].trimStart, const Duration(seconds: 8));
      expect(clips[1].cutStart, const Duration(seconds: 8));
      // Gap still present.
      expect(clips[1].cutStart - clips[0].cutEnd, const Duration(seconds: 3));
    });
  });

  group('mergeSeam', () {
    test('adjacent boundary, no trim: merges into a single slice covering full source', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ]);
      c.mergeSeam(0);
      final clips = c.current.timeline.clips;
      expect(clips.length, 1);
      expect(clips[0].cutStart, Duration.zero);
      expect(clips[0].cutEnd, const Duration(seconds: 10));
      expect(clips[0].trimStart, Duration.zero);
      expect(clips[0].trimEnd, const Duration(seconds: 10));
    });

    test('adjacent boundary, with trim: keeps outer trims, drops inner trims', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, ts: 1, te: 4),
        _slice(cs: 5, ce: 10, ts: 7, te: 9),
      ]);
      c.mergeSeam(0);
      final clips = c.current.timeline.clips;
      expect(clips.length, 1);
      expect(clips[0].cutStart, Duration.zero);
      expect(clips[0].cutEnd, const Duration(seconds: 10));
      expect(clips[0].trimStart, const Duration(seconds: 1));
      expect(clips[0].trimEnd, const Duration(seconds: 9));
    });

    test('non-adjacent source boundary: merged slice covers the gap', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 8, ce: 12),
      ]);
      c.mergeSeam(0);
      final clips = c.current.timeline.clips;
      expect(clips.length, 1);
      expect(clips[0].cutStart, Duration.zero);
      expect(clips[0].cutEnd, const Duration(seconds: 12));
      // Trim bounds clamped to the new cut bounds.
      expect(clips[0].trimStart, Duration.zero);
      expect(clips[0].trimEnd, const Duration(seconds: 12));
    });

    test('reduces clip count by exactly 1', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
        _slice(cs: 10, ce: 15),
      ]);
      c.mergeSeam(0);
      expect(c.current.timeline.clips.length, 2);
    });

    test('preserves the third (untouched) slice verbatim', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
        _slice(cs: 10, ce: 15, ts: 11),
      ]);
      c.mergeSeam(0);
      final last = c.current.timeline.clips.last;
      expect(last.cutStart, const Duration(seconds: 10));
      expect(last.cutEnd, const Duration(seconds: 15));
      expect(last.trimStart, const Duration(seconds: 11));
    });

    test('out-of-range index is a no-op', () {
      final initial = [_slice(cs: 0, ce: 5)];
      final c = _controllerWithClips(initial);
      final before = c.current;
      c.mergeSeam(-1);
      c.mergeSeam(0);
      c.mergeSeam(5);
      expect(identical(c.current, before), true);
    });
  });
}
