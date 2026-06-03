import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  group('v7 -> v8 migration', () {
    test('bumps schemaVersion to 8', () {
      final v7 = {
        'schemaVersion': 7,
        'timeline': {
          'zoomTracks': [],
          'clips': [
            {
              'startMicros': 0,
              'endMicros': 12000000,
              'playbackSpeed': 1.0,
              'fadeInMicros': 0,
              'fadeOutMicros': 0,
              'micGainPercent': 100,
              'micMuted': false,
              'systemGainPercent': 100,
              'systemMuted': false,
              'hideCursor': false,
              'disableSmoothMouse': false,
            }
          ],
        },
      };
      final out = migrateEditorProjectJson(v7,
          videoDuration: const Duration(seconds: 12));
      expect(out['schemaVersion'], 8);
    });

    test('renames startMicros -> cutStartMicros and duplicates to trimStartMicros', () {
      final v7 = {
        'schemaVersion': 7,
        'timeline': {
          'zoomTracks': [],
          'clips': [
            {'startMicros': 1000000, 'endMicros': 11000000},
          ],
        },
      };
      final out = migrateEditorProjectJson(v7,
          videoDuration: const Duration(seconds: 12));
      final clip = (out['timeline'] as Map)['clips'][0] as Map;
      expect(clip['cutStartMicros'], 1000000);
      expect(clip['cutEndMicros'], 11000000);
      expect(clip['trimStartMicros'], 1000000);
      expect(clip['trimEndMicros'], 11000000);
      expect(clip.containsKey('startMicros'), false);
      expect(clip.containsKey('endMicros'), false);
    });

    test('preserves all non-bound clip fields', () {
      final v7 = {
        'schemaVersion': 7,
        'timeline': {
          'zoomTracks': [],
          'clips': [
            {
              'startMicros': 0,
              'endMicros': 12000000,
              'playbackSpeed': 2.0,
              'fadeInMicros': 500000,
              'fadeOutMicros': 250000,
              'micGainPercent': 75,
              'micMuted': true,
              'systemGainPercent': 50,
              'systemMuted': false,
              'hideCursor': true,
              'disableSmoothMouse': true,
            }
          ],
        },
      };
      final out = migrateEditorProjectJson(v7,
          videoDuration: const Duration(seconds: 12));
      final clip = (out['timeline'] as Map)['clips'][0] as Map;
      expect(clip['playbackSpeed'], 2.0);
      expect(clip['fadeInMicros'], 500000);
      expect(clip['micGainPercent'], 75);
      expect(clip['micMuted'], true);
      expect(clip['hideCursor'], true);
      expect(clip['disableSmoothMouse'], true);
    });

    test('handles missing clips list (defensive: blank timeline)', () {
      final v7 = {
        'schemaVersion': 7,
        'timeline': {'zoomTracks': []},
      };
      final out = migrateEditorProjectJson(v7,
          videoDuration: const Duration(seconds: 12));
      expect(out['schemaVersion'], 8);
      final timeline = out['timeline'] as Map;
      // 'clips' may be missing or empty — both acceptable post-migration.
      final clips = timeline['clips'];
      expect(clips == null || (clips is List && clips.isEmpty), true);
    });

    test('full v7 fixture round-trips through fromJson without throwing', () {
      final v7 = {
        'schemaVersion': 7,
        'timeline': {
          'zoomTracks': [],
          'clips': [
            {
              'startMicros': 0,
              'endMicros': 12000000,
              'playbackSpeed': 1.5,
              'micGainPercent': 80,
              'micMuted': false,
              'systemGainPercent': 100,
              'systemMuted': false,
              'hideCursor': false,
              'disableSmoothMouse': false,
            }
          ],
        },
      };
      final state = EditorProjectState.fromJson(
        v7,
        videoDuration: const Duration(seconds: 12),
      );
      final c = state.timeline.clips.single;
      expect(c.cutStart, Duration.zero);
      expect(c.cutEnd, const Duration(seconds: 12));
      expect(c.trimStart, Duration.zero);
      expect(c.trimEnd, const Duration(seconds: 12));
      expect(c.playbackSpeed, 1.5);
      expect(c.micGainPercent, 80);
    });
  });
}
