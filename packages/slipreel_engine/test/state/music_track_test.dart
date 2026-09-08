import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/music_track.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';
import 'package:slipreel_engine/state/editor_history_controller.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  const music = MusicTrack(
    path: '/music.m4a',
    name: 'Test',
    sourceDuration: 8,
    start: 2,
    trimStart: 1,
    trimEnd: 5,
    volume: 0.4,
    duck: true,
  );
  test(
    'music survives save/load with every setting and removal is undoable',
    () async {
      final folder = await Directory.systemTemp.createTemp('music-store-test');
      final controller = EditorProjectController();
      final history = EditorHistoryController(controller: controller)..start();
      try {
        controller.setMusic(music);
        final store = EditorProjectStore(videoPath: '${folder.path}/video.mp4');
        await store.save(controller.current);
        final loaded = await store.load(
          videoDuration: const Duration(seconds: 10),
        );
        expect(loaded.timeline.music, music);
        history.undo();
        expect(controller.current.timeline.music, isNull);
        history.redo();
        expect(controller.current.timeline.music, music);
        controller.setMusic(null);
        expect(controller.current.timeline.music, isNull);
        history.undo();
        expect(controller.current.timeline.music, music);
      } finally {
        history.dispose();
        controller.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'old timelines default to no music and malformed values are bounded',
    () {
      expect(Timeline.fromJson({}).music, isNull);
    const defaults = MusicTrack(path:'/tone.wav',name:'Tone',sourceDuration:4);
    expect(MusicTrack.fromJson(defaults.toJson()),defaults);
      final restored = MusicTrack.fromJson({
        ...music.toJson(),
        'volume': 900,
        'trimStart': 999,
        'start': -2,
      });
      expect(restored.volume, 2);
      expect(restored.trimStart, 8);
      expect(restored.start, 0);
      expect(
        Timeline.fromJson({
          'music': {'name': 42},
        }).music,
        isNull,
      );
    },
  );
  test('looping, trimmed, and out-of-video track spans', () {
    expect(music.length(10), 8);
    expect(music.copyWith(loop: false).length(10), 4);
    expect(music.copyWith(start: 12).length(10), 0);
    expect(music.copyWith(loop: false, start: 9).length(10), 1);
  });
  test('endOverride caps the bed and survives round trip', () {
    // Looping bed (start 2) normally fills to the video end (len 8); an
    // override at t=6 stops it early: 6 - 2 = 4.
    expect(music.copyWith(endOverride: 6).length(10), 4);
    // Non-loop bed already plays only its 4s segment; an override at t=3
    // shortens it further to 1s and never extends it past the segment.
    expect(music.copyWith(loop: false, endOverride: 3).length(10), 1);
    expect(music.copyWith(loop: false, endOverride: 9).length(10), 4);
    // Override past the video end is clamped by the available span.
    expect(music.copyWith(endOverride: 99).length(10), 8);
    // Sentinel copyWith clears it back to the natural fill.
    final capped = music.copyWith(endOverride: 6);
    expect(capped.copyWith(endOverride: null).length(10), 8);
    // Leaving it unset keeps the stored override.
    expect(capped.copyWith(volume: 0.5).length(10), 4);
    expect(MusicTrack.fromJson(capped.toJson()), capped);
  });
}
