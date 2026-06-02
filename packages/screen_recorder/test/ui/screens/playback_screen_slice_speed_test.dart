// Tests for the slice-driven preview-playback-speed wiring on
// PlaybackScreen.
//
// Same constraint as playback_screen_preview_speed_test.dart: full
// PlaybackScreen widget tests require a real video file + a live
// RecordingMetadata sidecar (see playback_screen_export_test.dart),
// neither of which is available in the unit-test sandbox.
//
// We exercise the same seams the screen uses:
//   1. The selector
//        s.timeline.clips.isEmpty ? 1.0 : s.timeline.clips.first.playbackSpeed
//      that drives the screen's `ref.listen<double>` re-apply path.
//   2. EditorProjectController.setSliceSpeed(0, x) — the mutator the
//      slice editor will call.
//   3. effectivePreviewRate(sliceSpeed, previewSpeed) — the product
//      pushed to the video controller.
//   4. shouldReapplyOnResume — the play-state edge that triggers
//      _applyEffectivePlaybackSpeed on resume.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/playback_screen.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// Mirrors the selector inside [PlaybackScreen]'s `ref.listen<double>`:
///   `(s) => s.timeline.clips.isEmpty ? 1.0 : s.timeline.clips.first.playbackSpeed`.
double _sliceSpeedSelector(EditorProjectState s) =>
    s.timeline.clips.isEmpty ? 1.0 : s.timeline.clips.first.playbackSpeed;

EditorProjectState _stateWithSliceSpeed(double speed) {
  final base = EditorProjectState.defaults();
  return base.copyWith(
    timeline: base.timeline.copyWith(
      clips: [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 10),
          playbackSpeed: speed,
        ),
      ],
    ),
  );
}

void main() {
  group('slice-speed selector', () {
    test('returns 1.0 when timeline.clips is empty', () {
      final base = EditorProjectState.defaults();
      final empty = base.copyWith(
        timeline: base.timeline.copyWith(clips: const <ClipSlice>[]),
      );
      expect(_sliceSpeedSelector(empty), 1.0);
    });

    test('returns clips[0].playbackSpeed when present', () {
      expect(_sliceSpeedSelector(_stateWithSliceSpeed(2.0)), 2.0);
      expect(_sliceSpeedSelector(_stateWithSliceSpeed(0.5)), 0.5);
    });
  });

  group('setSliceSpeed drives the effective preview rate', () {
    test('setSliceSpeed(0, 2.0) updates effective rate to 2.0', () {
      // Boot a controller seeded with one 10s clip @1.0x — same shape
      // the playback screen restores from the project store.
      final container = ProviderContainer(overrides: [
        editorProjectControllerProvider.overrideWith(
          (ref) => EditorProjectController(
            initial: _stateWithSliceSpeed(1.0),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      // The screen records every selector emission via its
      // `ref.listen<double>(...)`. We mimic that with a sub-listener
      // so the test sees exactly what the screen would observe.
      final emissions = <double>[];
      container.listen<double>(
        editorProjectControllerProvider
            .select((s) => _sliceSpeedSelector(s)),
        (_, next) => emissions.add(next),
      );

      // Drive the slice mutation that the slice editor will trigger.
      container
          .read(editorProjectControllerProvider.notifier)
          .setSliceSpeed(0, 2.0);

      // The screen's listener forwards `next` directly into
      // _applyEffectivePlaybackSpeed, which (with the default
      // _previewPlaybackSpeed=1.0) pushes effectivePreviewRate to the
      // video controller. Verify both legs of that pipeline.
      expect(emissions, [2.0]);
      const previewSpeed = 1.0;
      expect(effectivePreviewRate(emissions.single, previewSpeed), 2.0);
    });

    test('setSliceSpeed multiplied with preview rate 2x gives 3.0', () {
      // Start at 1.5x slice, the dropdown lifts preview to 2.0; the
      // effective rate the screen pushes to the controller is the
      // product.
      final container = ProviderContainer(overrides: [
        editorProjectControllerProvider.overrideWith(
          (ref) => EditorProjectController(
            initial: _stateWithSliceSpeed(1.5),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final sliceSpeed = _sliceSpeedSelector(
        container.read(editorProjectControllerProvider),
      );
      expect(sliceSpeed, 1.5);

      // The dropdown change is a pure-local setState in the screen
      // (the preview multiplier is session-only, not on the project
      // state). The seam we exercise is the same math the screen
      // applies in its `onPreviewSpeedChanged` -> reapply path.
      const previewSpeed = 2.0;
      expect(effectivePreviewRate(sliceSpeed, previewSpeed), 3.0);
    });

    test('out-of-range setSliceSpeed clamps before the listener fires', () {
      // setSliceSpeed clamps to [0.25, 4.0]; the screen must see the
      // clamped value, not the raw input.
      final container = ProviderContainer(overrides: [
        editorProjectControllerProvider.overrideWith(
          (ref) => EditorProjectController(
            initial: _stateWithSliceSpeed(1.0),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final emissions = <double>[];
      container.listen<double>(
        editorProjectControllerProvider
            .select((s) => _sliceSpeedSelector(s)),
        (_, next) => emissions.add(next),
      );

      container
          .read(editorProjectControllerProvider.notifier)
          .setSliceSpeed(0, 10.0);
      expect(emissions, [4.0],
          reason: 'over-range value clamps to the 4.0 ceiling');
    });
  });

  group('resume from pause re-applies effective slice speed', () {
    // _onPlayStateTick re-applies the cached clipSpeed on the
    // false->true edge because AVPlayer (video_player on macOS)
    // silently resets `rate` to 1.0 on every play(). If the user
    // bumped the slice to 2x, that 2x has to survive pause/resume.
    test('re-applies the cached slice speed on the resume edge', () {
      // Cache the slice speed that the listener handed the screen.
      const sliceSpeed = 2.0;
      double controllerRate = effectivePreviewRate(sliceSpeed, 1.0);
      expect(controllerRate, 2.0);

      // Pause: true -> false, no re-apply.
      var prevIsPlaying = true;
      var isPlaying = false;
      if (shouldReapplyOnResume(prev: prevIsPlaying, next: isPlaying)) {
        controllerRate = effectivePreviewRate(sliceSpeed, 1.0);
      }
      prevIsPlaying = isPlaying;
      expect(controllerRate, 2.0, reason: 'pause leaves rate untouched');

      // Resume: false -> true. AVPlayer reset rate to 1.0 silently;
      // the edge listener must push the cached 2x back on.
      controllerRate = 1.0; // AVPlayer's silent reset.
      isPlaying = true;
      if (shouldReapplyOnResume(prev: prevIsPlaying, next: isPlaying)) {
        controllerRate = effectivePreviewRate(sliceSpeed, 1.0);
      }
      prevIsPlaying = isPlaying;
      expect(controllerRate, 2.0,
          reason: 'resume re-applies the cached slice speed');
    });
  });
}
