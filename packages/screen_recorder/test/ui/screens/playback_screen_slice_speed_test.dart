// Tests for the per-slice playback-speed wiring on PlaybackScreen.
//
// Full PlaybackScreen widget tests require a real video file + a live
// RecordingMetadata sidecar (see playback_screen_export_test.dart),
// neither of which is available in the unit-test sandbox.
//
// We exercise the same seams the screen uses:
//   1. The pure helpers [activeSliceIndex] / [effectiveClipSpeedAt]
//      that drive [_onSpeedTick]'s boundary-crossing detection and
//      the rate-applied-on-resume path.
//   2. The whole-clips-list selector that drives the `ref.listen` —
//      previously hard-coded to `clips.first.playbackSpeed`, now
//      watches the entire `timeline.clips` list so edits to any
//      slice's speed reach the player.
//   3. [EditorProjectController.setSliceSpeed] — the mutator the slice
//      editor calls; verified against arbitrary slice indices, not
//      just slice 0.
//   4. [effectivePreviewRate] / [shouldReapplyOnResume] — preserved
//      from the earlier single-slice-only era and still valid.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/playback_screen.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

ClipSlice _slice({
  int cs = 0,
  int ce = 10,
  double speed = 1.0,
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      playbackSpeed: speed,
    );

EditorProjectState _stateWithClips(List<ClipSlice> clips) {
  final base = EditorProjectState.defaults();
  return base.copyWith(
    timeline: base.timeline.copyWith(clips: clips),
  );
}

Duration _s(int s) => Duration(seconds: s);

void main() {
  group('activeSliceIndex', () {
    test('empty clips -> -1', () {
      expect(activeSliceIndex(const [], _s(3)), -1);
    });

    test('inside the only slice -> 0', () {
      final clips = [_slice(cs: 0, ce: 10)];
      expect(activeSliceIndex(clips, _s(0)), 0);
      expect(activeSliceIndex(clips, _s(5)), 0);
    });

    test('exactly at trimStart -> that slice (inclusive on the left)', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ];
      expect(activeSliceIndex(clips, _s(5)), 1,
          reason: 'pos == trimStart of slice 1 belongs to slice 1');
    });

    test('exactly at trimEnd -> NOT that slice (exclusive on the right)', () {
      final clips = [_slice(cs: 0, ce: 5)];
      expect(activeSliceIndex(clips, _s(5)), -1,
          reason: 'pos == trimEnd is past the slice — boundary handling');
    });

    test('inside slice 1 of N -> 1', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 12),
      ];
      expect(activeSliceIndex(clips, _s(7)), 1);
    });

    test('in a gap between non-adjacent slices -> -1', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 8, ce: 12),
      ];
      expect(activeSliceIndex(clips, _s(6)), -1,
          reason: 'gap between slices is not inside any slice');
    });

    test('past the final trimEnd -> -1', () {
      final clips = [_slice(cs: 0, ce: 5)];
      expect(activeSliceIndex(clips, _s(99)), -1);
    });
  });

  group('effectiveClipSpeedAt', () {
    test('empty clips -> 1.0 fallback', () {
      expect(effectiveClipSpeedAt(const [], _s(3)), 1.0);
    });

    test('inside slice -> that slice\'s speed', () {
      final clips = [
        _slice(cs: 0, ce: 5, speed: 1.0),
        _slice(cs: 5, ce: 10, speed: 2.5),
      ];
      expect(effectiveClipSpeedAt(clips, _s(3)), 1.0);
      expect(effectiveClipSpeedAt(clips, _s(7)), 2.5);
    });

    test('crossing the seam returns the destination slice\'s speed', () {
      // The exact-seam case is what _onSpeedTick races against: as the
      // smoothed playhead crosses sourcePos == 5, we must read slice
      // 1's speed (2x), not slice 0's (1x). Without the boundary-aware
      // resolver the player would keep slice 0's rate forever.
      final clips = [
        _slice(cs: 0, ce: 5, speed: 1.0),
        _slice(cs: 5, ce: 10, speed: 2.0),
      ];
      expect(effectiveClipSpeedAt(clips, _s(5)), 2.0);
    });

    test('past the final trimEnd -> nearest slice\'s speed', () {
      // When the playhead overshoots (transient) we still want a
      // sensible rate. Fall back to the last slice's speed via
      // clipSliceAt's "nearest slice" semantics.
      final clips = [_slice(cs: 0, ce: 5, speed: 1.5)];
      expect(effectiveClipSpeedAt(clips, _s(99)), 1.5);
    });

    test('in a gap between slices -> still falls back to a real slice', () {
      // clipSliceAt returns the LAST slice when in a gap past slice 0
      // — covering this so a future refactor doesn't accidentally
      // start returning 1.0 (which would silently regress the rate).
      final clips = [
        _slice(cs: 0, ce: 5, speed: 1.0),
        _slice(cs: 8, ce: 12, speed: 2.0),
      ];
      // Position 6 is between slice 0 (ends at 5) and slice 1 (starts
      // at 8). clipSliceAt picks slice 1 (first slice whose trimEnd >
      // pos in source order is actually slice 0's, but clipSliceAt's
      // fallback when no slice contains pos is `clips.last`).
      expect(effectiveClipSpeedAt(clips, _s(6)), 2.0);
    });
  });

  group('whole-clips-list selector (replaces the old slice-0 selector)', () {
    // The screen now watches `s.timeline.clips` itself — not just
    // `clips.first.playbackSpeed` — so editing slice 1's speed reaches
    // the player just like editing slice 0's does. The listener
    // callback then evaluates `effectiveClipSpeedAt(clips, pos)` at the
    // CURRENT playhead position rather than blindly applying the
    // selector's projection.

    test('fires on any slice mutation, not just slice 0', () {
      final container = ProviderContainer(overrides: [
        editorProjectControllerProvider.overrideWith(
          (ref) => EditorProjectController(
            initial: _stateWithClips([
              _slice(cs: 0, ce: 5, speed: 1.0),
              _slice(cs: 5, ce: 10, speed: 1.0),
            ]),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final emissions = <List<double>>[];
      container.listen<List<ClipSlice>>(
        editorProjectControllerProvider.select((s) => s.timeline.clips),
        (_, next) => emissions.add(next.map((c) => c.playbackSpeed).toList()),
      );

      // Mutate slice 1 (NOT slice 0). The old slice-0-only listener
      // would have skipped this; the new whole-list listener must fire.
      container
          .read(editorProjectControllerProvider.notifier)
          .setSliceSpeed(1, 2.0);
      expect(emissions.length, 1,
          reason: 'listener must fire when ANY slice\'s speed changes');
      expect(emissions.single, [1.0, 2.0]);

      // Also fires on slice 0 edits — old behaviour preserved.
      container
          .read(editorProjectControllerProvider.notifier)
          .setSliceSpeed(0, 0.5);
      expect(emissions.length, 2);
      expect(emissions.last, [0.5, 2.0]);
    });

    test(
        'listener payload combined with playhead position resolves the '
        'right active-slice speed', () {
      final container = ProviderContainer(overrides: [
        editorProjectControllerProvider.overrideWith(
          (ref) => EditorProjectController(
            initial: _stateWithClips([
              _slice(cs: 0, ce: 5, speed: 1.0),
              _slice(cs: 5, ce: 10, speed: 4.0),
            ]),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final state = container.read(editorProjectControllerProvider);
      final clips = state.timeline.clips;

      // Playhead in slice 0 at pos 2s -> 1.0
      expect(effectiveClipSpeedAt(clips, _s(2)), 1.0);
      // Playhead in slice 1 at pos 7s -> 4.0 (this is what the old
      // slice-0-only design got wrong)
      expect(effectiveClipSpeedAt(clips, _s(7)), 4.0);

      // Multiplied by preview speed = controller rate.
      expect(effectivePreviewRate(1.0, 2.0), 2.0);
      expect(effectivePreviewRate(4.0, 2.0), 8.0);
    });
  });

  group('setSliceSpeed for non-first slices', () {
    test('setSliceSpeed(1, 2.0) updates clips[1] without touching clips[0]', () {
      final container = ProviderContainer(overrides: [
        editorProjectControllerProvider.overrideWith(
          (ref) => EditorProjectController(
            initial: _stateWithClips([
              _slice(cs: 0, ce: 5, speed: 1.0),
              _slice(cs: 5, ce: 10, speed: 1.0),
            ]),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      container
          .read(editorProjectControllerProvider.notifier)
          .setSliceSpeed(1, 2.0);
      final clips =
          container.read(editorProjectControllerProvider).timeline.clips;
      expect(clips[0].playbackSpeed, 1.0);
      expect(clips[1].playbackSpeed, 2.0);
    });

    test('out-of-range setSliceSpeed clamps to [0.25, 24.0]', () {
      final container = ProviderContainer(overrides: [
        editorProjectControllerProvider.overrideWith(
          (ref) => EditorProjectController(
            initial: _stateWithClips([_slice(cs: 0, ce: 10, speed: 1.0)]),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      container
          .read(editorProjectControllerProvider.notifier)
          .setSliceSpeed(0, 99.0);
      expect(
        container
            .read(editorProjectControllerProvider)
            .timeline
            .clips
            .single
            .playbackSpeed,
        24.0,
        reason: 'over-range value clamps to the 24.0 ceiling',
      );
    });
  });

  group('resume from pause re-applies the slice-under-playhead speed', () {
    // _onPlayStateTick re-applies on the false->true edge because
    // AVPlayer (video_player on macOS) silently resets `rate` to 1.0
    // on every play(). Previously it re-applied a cached slice-0
    // value; now it re-evaluates from the current playhead position
    // via effectiveClipSpeedAt so resuming inside slice 1+ uses that
    // slice's speed.
    test('uses effectiveClipSpeedAt at the current source pos on resume',
        () {
      final clips = [
        _slice(cs: 0, ce: 5, speed: 1.0),
        _slice(cs: 5, ce: 10, speed: 2.0),
      ];
      const previewSpeed = 1.0;

      // Pretend the user has scrubbed into slice 1 and pressed
      // Space twice (pause->resume).
      final pos = _s(7);

      // Pause: true -> false, no re-apply.
      var prevIsPlaying = true;
      var isPlaying = false;
      double controllerRate = effectivePreviewRate(
        effectiveClipSpeedAt(clips, pos),
        previewSpeed,
      );
      expect(controllerRate, 2.0,
          reason: 'pre-pause rate reflects slice 1\'s 2.0x speed');
      if (shouldReapplyOnResume(prev: prevIsPlaying, next: isPlaying)) {
        controllerRate = effectivePreviewRate(
          effectiveClipSpeedAt(clips, pos),
          previewSpeed,
        );
      }
      prevIsPlaying = isPlaying;
      expect(controllerRate, 2.0, reason: 'pause leaves rate untouched');

      // Resume: AVPlayer silently dropped rate to 1.0 — the edge
      // listener re-derives the rate from the CURRENT playhead
      // position (slice 1), not from a stale cache pinned to slice 0.
      controllerRate = 1.0;
      isPlaying = true;
      if (shouldReapplyOnResume(prev: prevIsPlaying, next: isPlaying)) {
        controllerRate = effectivePreviewRate(
          effectiveClipSpeedAt(clips, pos),
          previewSpeed,
        );
      }
      expect(controllerRate, 2.0,
          reason: 'resume inside slice 1 restores slice 1\'s 2.0x speed, '
              'not slice 0\'s 1.0x as the old cached-value design did');
    });

    test('pause inside slice 0, resume restores slice 0 speed', () {
      // Mirror case: confirms the resume path still works for slice 0
      // (the old, narrower behaviour is preserved as a subset of the
      // new whole-list behaviour).
      final clips = [
        _slice(cs: 0, ce: 5, speed: 1.5),
        _slice(cs: 5, ce: 10, speed: 0.5),
      ];
      const previewSpeed = 1.0;
      final pos = _s(2);

      double controllerRate = 1.0; // simulated AVPlayer reset
      if (shouldReapplyOnResume(prev: false, next: true)) {
        controllerRate = effectivePreviewRate(
          effectiveClipSpeedAt(clips, pos),
          previewSpeed,
        );
      }
      expect(controllerRate, 1.5);
    });
  });

  test('previewVolumeForSpeed silences audio above the threshold', () {
    expect(previewVolumeForSpeed(1.0), 1.0);
    expect(previewVolumeForSpeed(4.0), 1.0);
    expect(previewVolumeForSpeed(8.0), 0.0);
    expect(previewVolumeForSpeed(24.0), 0.0);
  });
}
