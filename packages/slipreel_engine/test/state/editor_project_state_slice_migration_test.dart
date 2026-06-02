import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  group('EditorProjectState schema v6 -> v7 migration', () {
    test('currentSchemaVersion is 7', () {
      expect(EditorProjectState.currentSchemaVersion, 7);
    });

    test('migrates v6 globals into a single clip covering the whole video', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'playbackSpeed': 1.5,
        'fadeInMicros': 500_000,
        'fadeOutMicros': 250_000,
        'audioMix': {
          'micGainPercent': 120,
          'micMuted': true,
          'systemGainPercent': 80,
          'systemMuted': false,
        },
        'timeline': {
          'zoomTracks': [
            {'regions': []},
          ],
        },
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 12, milliseconds: 340),
      );
      expect(v7['schemaVersion'], 7);
      final timeline = v7['timeline'] as Map<String, dynamic>;
      final clips = timeline['clips'] as List;
      expect(clips, hasLength(1));
      final clip = ClipSlice.fromJson(clips.first as Map<String, dynamic>);
      expect(clip.start, Duration.zero);
      expect(clip.end, const Duration(seconds: 12, milliseconds: 340));
      expect(clip.playbackSpeed, 1.5);
      expect(clip.fadeIn, const Duration(microseconds: 500_000));
      expect(clip.fadeOut, const Duration(microseconds: 250_000));
      expect(clip.micGainPercent, 120);
      expect(clip.micMuted, isTrue);
      expect(clip.systemGainPercent, 80);
      expect(clip.systemMuted, isFalse);
      expect(clip.hideCursor, isFalse);
      expect(clip.disableSmoothMouse, isFalse);
    });

    test('migrates a v6 without audioMix using default audio values', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'timeline': {'zoomTracks': []},
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 5),
      );
      final clips = (v7['timeline'] as Map<String, dynamic>)['clips'] as List;
      final clip = ClipSlice.fromJson(clips.first as Map<String, dynamic>);
      expect(clip.playbackSpeed, 1.0);
      expect(clip.fadeIn, Duration.zero);
      expect(clip.fadeOut, Duration.zero);
      expect(clip.micGainPercent, 100);
      expect(clip.micMuted, isFalse);
      expect(clip.systemGainPercent, 100);
      expect(clip.systemMuted, isFalse);
    });

    test('v7 JSON has no top-level playbackSpeed/fade/audioMix', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'playbackSpeed': 1.5,
        'fadeInMicros': 500_000,
        'fadeOutMicros': 250_000,
        'audioMix': {'micGainPercent': 120, 'micMuted': true},
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 10),
      );
      expect(v7.containsKey('playbackSpeed'), isFalse);
      expect(v7.containsKey('fadeInMicros'), isFalse);
      expect(v7.containsKey('fadeOutMicros'), isFalse);
      expect(v7.containsKey('audioMix'), isFalse);
    });

    test('v6 without a timeline key still produces a v7 with a clip', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'playbackSpeed': 2.0,
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 3),
      );
      final timeline = v7['timeline'] as Map<String, dynamic>;
      final clips = timeline['clips'] as List;
      expect(clips, hasLength(1));
      final clip = ClipSlice.fromJson(clips.first as Map<String, dynamic>);
      expect(clip.playbackSpeed, 2.0);
      expect(clip.end, const Duration(seconds: 3));
    });
  });
}
