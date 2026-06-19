import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/feel_variant.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';

/// Debug-only A/B harness: applies a [FeelVariant] bundle through the
/// existing editor + motion-tuning setters so preview and export stay in
/// lockstep (no parallel override path). State is the active candidate index.
class FeelLabController extends StateNotifier<int> {
  FeelLabController(this._ref) : super(0);

  final Ref _ref;

  ScreenAnimationConfig? _entryScreen;
  CursorAnimationConfig? _entryCursor;
  MotionTuning? _entryTuning;

  void _snapshotIfNeeded() {
    if (_entryScreen != null) return;
    final project = _ref.read(editorProjectControllerProvider);
    _entryScreen = project.screenAnimationConfig;
    _entryCursor = project.cursorAnimationConfig;
    _entryTuning = _ref.read(motionTuningProvider);
  }

  void apply(int index) {
    _snapshotIfNeeded();
    final i = index % FeelVariant.candidates.length;
    final v = FeelVariant.candidates[i];
    final editor = _ref.read(editorProjectControllerProvider.notifier);
    editor.setScreenAnimationConfig(ScreenAnimationConfig.preset(v.screen));
    editor.setCursorAnimationConfig(CursorAnimationConfig.preset(v.cursor));
    _ref.read(motionTuningProvider.notifier).usePreset(v.tuning);
    state = i;
  }

  void cycle() => apply(state + 1);
  void cyclePrev() => apply(
      (state - 1 + FeelVariant.candidates.length) % FeelVariant.candidates.length);

  void restore() {
    if (_entryScreen == null) return;
    final editor = _ref.read(editorProjectControllerProvider.notifier);
    editor.setScreenAnimationConfig(_entryScreen!);
    editor.setCursorAnimationConfig(_entryCursor!);
    _ref.read(motionTuningProvider.notifier).replace(_entryTuning!);
    _entryScreen = null;
    _entryCursor = null;
    _entryTuning = null;
    state = 0;
  }

  void commit() {
    _entryScreen = null;
    _entryCursor = null;
    _entryTuning = null;
  }

  String get activeLabel => FeelVariant.candidates[state].label;
}

final feelLabControllerProvider =
    StateNotifierProvider<FeelLabController, int>(
  (ref) => FeelLabController(ref),
);
