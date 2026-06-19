import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/feel_variant.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:screen_recorder/state/feel_lab_controller.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: EditorProjectState.defaults()),
      ),
    ]);
    addTearDown(container.dispose);
  });

  EditorProjectState editor() =>
      container.read(editorProjectControllerProvider);

  test('apply(i) writes the i-th variant through the existing setters', () {
    final lab = container.read(feelLabControllerProvider.notifier);
    lab.apply(2); // Studio Snappy
    final v = FeelVariant.candidates[2];
    expect(editor().screenAnimationConfig.preset, v.screen);
    expect(editor().cursorAnimationConfig.preset, v.cursor);
    expect(container.read(feelLabControllerProvider), 2);
  });

  test('cycle wraps around the candidate list', () {
    final lab = container.read(feelLabControllerProvider.notifier);
    for (var i = 0; i < FeelVariant.candidates.length; i++) {
      lab.cycle();
    }
    expect(container.read(feelLabControllerProvider), 0); // wrapped back
  });

  test('restore re-applies the entry snapshot taken on first apply', () {
    final lab = container.read(feelLabControllerProvider.notifier);
    final entryScreen = editor().screenAnimationConfig.preset;
    lab.apply(1);
    expect(editor().screenAnimationConfig.preset, isNot(entryScreen));
    lab.restore();
    expect(editor().screenAnimationConfig.preset, entryScreen);
    expect(container.read(feelLabControllerProvider), 0);
  });
}
