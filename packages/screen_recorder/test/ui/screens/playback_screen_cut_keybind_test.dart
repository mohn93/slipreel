import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

import 'package:screen_recorder/ui/screens/playback_screen.dart';

ClipSlice _slice(int cs, int ce) => ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
    );

EditorProjectController _controllerWithClips(List<ClipSlice> clips) {
  final base = EditorProjectState.defaults();
  return EditorProjectController(
    initial: base.copyWith(
      timeline: base.timeline.copyWith(clips: clips),
    ),
  );
}

void main() {
  group('handleCutKeybind (pure helper)', () {
    test('valid edited-time -> splitAtPlayhead returns true; state mutates', () {
      final c = _controllerWithClips([_slice(0, 10)]);
      final ok = handleCutKeybind(
        controller: c,
        currentEditedTime: const Duration(seconds: 4),
        clips: c.current.timeline.clips,
      );
      expect(ok, true);
      expect(c.current.timeline.clips.length, 2);
    });

    test('edited-time too close to slice edge -> returns false; no mutation', () {
      final c = _controllerWithClips([_slice(0, 10)]);
      final ok = handleCutKeybind(
        controller: c,
        currentEditedTime: const Duration(milliseconds: 50),
        clips: c.current.timeline.clips,
      );
      expect(ok, false);
      expect(c.current.timeline.clips.length, 1);
    });

    test('empty clips -> returns false', () {
      final c = _controllerWithClips(const []);
      final ok = handleCutKeybind(
        controller: c,
        currentEditedTime: const Duration(seconds: 1),
        clips: const [],
      );
      expect(ok, false);
    });
  });
}
