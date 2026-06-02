import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectController _controllerWithClips(List<ClipSlice> clips) {
  final base = EditorProjectState.defaults();
  return EditorProjectController(
    initial: base.copyWith(
      timeline: base.timeline.copyWith(clips: clips),
    ),
  );
}

ClipSlice _slice({
  int cs = 0,
  int ce = 10,
  double speed = 1.0,
  int micGain = 100,
  bool hideCursor = false,
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      playbackSpeed: speed,
      micGainPercent: micGain,
      hideCursor: hideCursor,
    );

void main() {
  group('splitSlice', () {
    test('splits at sourcePosition; both halves inherit parent settings', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 10, speed: 2.0, micGain: 50, hideCursor: true),
      ]);
      final ok = c.splitSlice(0, const Duration(seconds: 4));
      expect(ok, true);
      final clips = c.current.timeline.clips;
      expect(clips.length, 2);
      final left = clips[0];
      final right = clips[1];
      expect(left.cutStart, Duration.zero);
      expect(left.cutEnd, const Duration(seconds: 4));
      expect(left.trimStart, Duration.zero);
      expect(left.trimEnd, const Duration(seconds: 4));
      expect(right.cutStart, const Duration(seconds: 4));
      expect(right.cutEnd, const Duration(seconds: 10));
      expect(right.trimStart, const Duration(seconds: 4));
      expect(right.trimEnd, const Duration(seconds: 10));
      expect(left.playbackSpeed, 2.0);
      expect(right.playbackSpeed, 2.0);
      expect(left.micGainPercent, 50);
      expect(right.micGainPercent, 50);
      expect(left.hideCursor, true);
      expect(right.hideCursor, true);
    });

    test('rejects split when out of slice range', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 10)]);
      expect(c.splitSlice(0, const Duration(seconds: 12)), false);
      expect(c.current.timeline.clips.length, 1);
    });

    test('rejects split too close to left edge (<100ms)', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 10)]);
      expect(c.splitSlice(0, const Duration(milliseconds: 50)), false);
      expect(c.current.timeline.clips.length, 1);
    });

    test('rejects split too close to right edge (<100ms)', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 10)]);
      expect(
        c.splitSlice(0, const Duration(milliseconds: 9950)),
        false,
      );
      expect(c.current.timeline.clips.length, 1);
    });

    test('out-of-range sliceIndex is a no-op returning false', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 10)]);
      expect(c.splitSlice(99, const Duration(seconds: 5)), false);
      expect(c.current.timeline.clips.length, 1);
    });

    test('respects existing trim bounds: split at sourcePosition outside trim fails', () {
      // Slice has cut [0,10] but trimmed to [3,8]. Splitting at source 1s
      // is inside cut but outside trim — should fail because the cut is
      // an edited-time operation.
      final c = _controllerWithClips([
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 10),
          trimStart: const Duration(seconds: 3),
          trimEnd: const Duration(seconds: 8),
        ),
      ]);
      expect(c.splitSlice(0, const Duration(seconds: 1)), false);
    });

    test('inserts at the correct index when splitting a middle slice', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10), // splitting this one
        _slice(cs: 10, ce: 15),
      ]);
      expect(c.splitSlice(1, const Duration(seconds: 7)), true);
      final clips = c.current.timeline.clips;
      expect(clips.length, 4);
      expect(clips[1].cutEnd, const Duration(seconds: 7));
      expect(clips[2].cutStart, const Duration(seconds: 7));
      expect(clips[2].cutEnd, const Duration(seconds: 10));
      expect(clips[3].cutStart, const Duration(seconds: 10));
    });
  });

  group('setSliceTrimStart / setSliceTrimEnd', () {
    test('setSliceTrimStart clamps below cutStart', () {
      final c = _controllerWithClips([_slice(cs: 2, ce: 10)]);
      c.setSliceTrimStart(0, Duration.zero);
      expect(c.current.timeline.clips[0].trimStart, const Duration(seconds: 2));
    });

    test('setSliceTrimStart clamps above trimEnd - 100ms', () {
      final c = _controllerWithClips([
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 10),
          trimEnd: const Duration(seconds: 5),
        ),
      ]);
      c.setSliceTrimStart(0, const Duration(seconds: 6));
      expect(
        c.current.timeline.clips[0].trimStart,
        const Duration(seconds: 4, milliseconds: 900),
      );
    });

    test('setSliceTrimStart no-op when unchanged', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 10)]);
      final before = c.current;
      c.setSliceTrimStart(0, Duration.zero);
      expect(identical(c.current, before), true);
    });

    test('setSliceTrimEnd clamps above cutEnd', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 5)]);
      c.setSliceTrimEnd(0, const Duration(seconds: 10));
      expect(c.current.timeline.clips[0].trimEnd, const Duration(seconds: 5));
    });

    test('setSliceTrimEnd clamps below trimStart + 100ms', () {
      final c = _controllerWithClips([
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 10),
          trimStart: const Duration(seconds: 3),
        ),
      ]);
      c.setSliceTrimEnd(0, const Duration(seconds: 1));
      expect(
        c.current.timeline.clips[0].trimEnd,
        const Duration(seconds: 3, milliseconds: 100),
      );
    });

    test('out-of-range index is a no-op', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 10)]);
      final before = c.current;
      c.setSliceTrimStart(99, Duration.zero);
      c.setSliceTrimEnd(99, Duration.zero);
      expect(identical(c.current, before), true);
    });
  });

  group('splitAtPlayhead', () {
    test('maps editedPosition -> source, finds slice, splits', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 12),
      ]);
      // Edited time 7s = source 7s = inside slice 1 [5,12].
      final ok = c.splitAtPlayhead(
          const Duration(seconds: 7), c.current.timeline.clips);
      expect(ok, true);
      expect(c.current.timeline.clips.length, 3);
    });

    test('returns false on empty clips', () {
      final c = _controllerWithClips(const []);
      expect(
        c.splitAtPlayhead(const Duration(seconds: 1), const []),
        false,
      );
    });

    test('returns false at exact boundary between slices', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ]);
      // Edited time 5s is the seam — too close to either slice's edge.
      final ok = c.splitAtPlayhead(
          const Duration(seconds: 5), c.current.timeline.clips);
      expect(ok, false);
    });
  });

  group('removeSlice (C activates B-era guard)', () {
    test('drops middle slice, surviving slices keep their cut bounds', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
        _slice(cs: 10, ce: 15),
      ]);
      c.removeSlice(1);
      final clips = c.current.timeline.clips;
      expect(clips.length, 2);
      expect(clips[0].cutEnd, const Duration(seconds: 5));
      expect(clips[1].cutStart, const Duration(seconds: 10));
      // The source range [5,10] is now a gap, removed from playback.
    });

    test('refuses to drop the only slice', () {
      final c = _controllerWithClips([_slice(cs: 0, ce: 10)]);
      c.removeSlice(0);
      expect(c.current.timeline.clips.length, 1);
    });
  });
}
