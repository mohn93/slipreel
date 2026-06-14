import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _stateWithOneSlice({
  Duration end = const Duration(seconds: 10),
}) {
  return EditorProjectState.defaults().copyWith(
    timeline: const Timeline(zoomTracks: []).copyWith(
      clips: [ClipSlice(cutStart: Duration.zero, cutEnd: end)],
    ),
  );
}

EditorProjectState _stateWithTwoSlices() {
  return EditorProjectState.defaults().copyWith(
    timeline: const Timeline(zoomTracks: []).copyWith(
      clips: [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 5)),
        ClipSlice(
          cutStart: const Duration(seconds: 5),
          cutEnd: const Duration(seconds: 10),
        ),
      ],
    ),
  );
}

void main() {
  group('EditorProjectController slice mutators', () {
    late EditorProjectController controller;
    setUp(() {
      controller = EditorProjectController(initial: _stateWithOneSlice());
    });

    test('setSliceSpeed updates clip 0 speed', () {
      controller.setSliceSpeed(0, 2.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 2.0);
    });

    test('setSliceSpeed clamps to [0.25, 24.0]', () {
      controller.setSliceSpeed(0, -1.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 0.25);
      controller.setSliceSpeed(0, 99.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 24.0);
      controller.setSliceSpeed(0, 8.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 8.0);
    });

    test('setSliceSpeed no-ops on NaN', () {
      controller.setSliceSpeed(0, double.nan);
      expect(controller.current.timeline.clips[0].playbackSpeed, 1.0);
    });

    test('setSliceSpeed no-ops when value equals current', () {
      var notifications = 0;
      controller.addListener((_) => notifications++);
      // addListener fires once immediately with the current state.
      final baseline = notifications;
      controller.setSliceSpeed(0, 1.0); // same as default
      expect(notifications - baseline, 0);
    });

    test('setSliceMicGain clamps to 0..200', () {
      controller.setSliceMicGain(0, -10);
      expect(controller.current.timeline.clips[0].micGainPercent, 0);
      controller.setSliceMicGain(0, 300);
      expect(controller.current.timeline.clips[0].micGainPercent, 200);
    });

    test('setSliceSystemGain clamps to 0..200', () {
      controller.setSliceSystemGain(0, -10);
      expect(controller.current.timeline.clips[0].systemGainPercent, 0);
      controller.setSliceSystemGain(0, 250);
      expect(controller.current.timeline.clips[0].systemGainPercent, 200);
    });

    test('setSliceMicMuted toggles', () {
      controller.setSliceMicMuted(0, true);
      expect(controller.current.timeline.clips[0].micMuted, isTrue);
    });

    test('setSliceSystemMuted toggles', () {
      controller.setSliceSystemMuted(0, true);
      expect(controller.current.timeline.clips[0].systemMuted, isTrue);
    });

    // m7: the global recording-audio control must reach EVERY slice, not just
    // clip 0, so a cut recording doesn't leave later slices at the old level.
    test('setAllMicGain applies to every slice (clamped, single update)', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      var notifications = 0;
      controller.addListener((_) => notifications++);
      final baseline = notifications;

      controller.setAllMicGain(250); // clamps to 200
      final clips = controller.current.timeline.clips;
      expect(clips.map((c) => c.micGainPercent), everyElement(200));
      expect(notifications - baseline, 1, reason: 'one state update for all');
    });

    test('setAllSystemGain applies to every slice', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      controller.setAllSystemGain(40);
      expect(controller.current.timeline.clips.map((c) => c.systemGainPercent),
          everyElement(40));
    });

    test('setAllMicMuted / setAllSystemMuted apply to every slice', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      controller.setAllMicMuted(true);
      controller.setAllSystemMuted(true);
      final clips = controller.current.timeline.clips;
      expect(clips.every((c) => c.micMuted && c.systemMuted), isTrue);
    });

    test('setAllMicGain no-ops when every slice already matches', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      controller.setAllMicGain(150);
      var notifications = 0;
      controller.addListener((_) => notifications++);
      final baseline = notifications;
      controller.setAllMicGain(150);
      expect(notifications - baseline, 0);
    });

    test('setSliceFadeIn clamps negatives to zero', () {
      controller.setSliceFadeIn(0, const Duration(seconds: -1));
      expect(controller.current.timeline.clips[0].fadeIn, Duration.zero);
    });

    test('setSliceFadeOut accepts a positive duration', () {
      controller.setSliceFadeOut(0, const Duration(milliseconds: 500));
      expect(
        controller.current.timeline.clips[0].fadeOut,
        const Duration(milliseconds: 500),
      );
    });

    test('setSliceHideCursor flips bool', () {
      controller.setSliceHideCursor(0, true);
      expect(controller.current.timeline.clips[0].hideCursor, isTrue);
    });

    test('setSliceDisableSmoothMouse flips bool', () {
      controller.setSliceDisableSmoothMouse(0, true);
      expect(
        controller.current.timeline.clips[0].disableSmoothMouse,
        isTrue,
      );
    });

    test('out-of-range sliceIndex no-ops without throwing', () {
      controller.setSliceSpeed(5, 2.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 1.0);
    });

    test('removeSlice no-ops when only one slice exists', () {
      controller.removeSlice(0);
      expect(controller.current.timeline.clips, hasLength(1));
    });

    test('removeSlice deletes a slice when more than one exists', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      controller.removeSlice(0);
      expect(controller.current.timeline.clips, hasLength(1));
      expect(
        controller.current.timeline.clips[0].start,
        const Duration(seconds: 5),
      );
    });

    test('removeSlice with out-of-range index no-ops', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      controller.removeSlice(99);
      expect(controller.current.timeline.clips, hasLength(2));
    });
  });
}
