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
      clips: [ClipSlice(start: Duration.zero, end: end)],
    ),
  );
}

EditorProjectState _stateWithTwoSlices() {
  return EditorProjectState.defaults().copyWith(
    timeline: const Timeline(zoomTracks: []).copyWith(
      clips: [
        ClipSlice(start: Duration.zero, end: const Duration(seconds: 5)),
        ClipSlice(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
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

    test('setSliceSpeed clamps to [0.25, 4.0]', () {
      controller.setSliceSpeed(0, -1.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 0.25);
      controller.setSliceSpeed(0, 99.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 4.0);
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
