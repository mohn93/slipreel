import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';

void main() {
  test('load uses seed when no sidecar exists', () async {
    final dir = await Directory.systemTemp.createTemp('seed_test');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/clip.mov';
    final store = EditorProjectStore(videoPath: videoPath);

    final seed = EditorProjectState.defaults().copyWith(
      outputAspect: OutputAspect.square1x1,
    );
    final loaded = await store.load(
      videoDuration: const Duration(seconds: 5),
      seed: seed,
    );

    expect(loaded.outputAspect, OutputAspect.square1x1);
    // Single slice still seeded over the video duration.
    expect(loaded.timeline.clips, isNotEmpty);
  });

  test('load ignores seed when a valid sidecar exists', () async {
    final dir = await Directory.systemTemp.createTemp('seed_test2');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/clip.mov';
    final store = EditorProjectStore(videoPath: videoPath);

    // Save a project with default (auto) aspect first.
    await store.save(EditorProjectState.defaults());

    final seed = EditorProjectState.defaults().copyWith(
      outputAspect: OutputAspect.square1x1,
    );
    final loaded = await store.load(
      videoDuration: const Duration(seconds: 5),
      seed: seed,
    );
    expect(loaded.outputAspect, OutputAspect.auto);
  });
}
