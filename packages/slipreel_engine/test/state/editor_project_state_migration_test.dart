import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  group('EditorProjectState.fromJson schema migration', () {
    test('JSON missing schemaVersion (legacy v1 file) parses via the '
        'migration chain into a valid v2 state', () {
      // Legacy recordings written before the schemaVersion field
      // existed have no version marker. The loader treats them as v1
      // and routes them through the v1→v2 migration step.
      // Migrated JSON should parse to all-defaults — no fields lost.
      final v1Json = <String, dynamic>{
        // No 'schemaVersion' key — that's the v1 hallmark.
        'zoomRegions': const <Map<String, dynamic>>[],
        'cursorSize': 1.5,
        'motionBlur': 0.3,
      };

      final state = EditorProjectState.fromJson(
        v1Json,
        videoDuration: const Duration(seconds: 60),
      );

      expect(state.cursorSize, 1.5);
      expect(state.motionBlur, 0.3);
      expect(state.zoomRegions, isEmpty);
      // Fields that didn't exist in v1 (or weren't in this fixture)
      // come from defaults.
      expect(state.cursorDelay.inMilliseconds, isPositive);
    });

    test('JSON with schemaVersion=2 passes through unchanged', () {
      final v2Json = EditorProjectState.defaults().toJson();
      // Sanity: defaults' toJson emits current schemaVersion.
      expect(v2Json['schemaVersion'], EditorProjectState.currentSchemaVersion);

      // Round-trip parse.
      final state = EditorProjectState.fromJson(
        v2Json,
        videoDuration: const Duration(seconds: 60),
      );
      expect(state.cursorSize, EditorProjectState.defaults().cursorSize);
    });

    test('JSON with schemaVersion newer than currentSchemaVersion throws', () {
      // A future build wrote a sidecar this build doesn't understand.
      // The loader must refuse to guess — silently parsing with
      // unknown shape would corrupt the user's project.
      final futureJson = <String, dynamic>{
        'schemaVersion': EditorProjectState.currentSchemaVersion + 5,
        'zoomRegions': const <Map<String, dynamic>>[],
      };

      expect(
        () => EditorProjectState.fromJson(
          futureJson,
          videoDuration: const Duration(seconds: 60),
        ),
        throwsFormatException,
      );
    });

    test('migration chain is composable: each step consumes vN and '
        'produces vN+1', () {
      // Direct unit test of the migration pipeline so future migrations
      // can be added with confidence the chain composes.
      final v1Json = <String, dynamic>{
        'cursorSize': 2.5,
        // No schemaVersion → v1
      };
      final migrated = migrateEditorProjectJson(
        v1Json,
        videoDuration: const Duration(seconds: 60),
      );
      expect(
        migrated['schemaVersion'],
        EditorProjectState.currentSchemaVersion,
        reason:
            'After migration, the JSON must declare the current '
            'schema version so downstream readers know what they have',
      );
      expect(
        migrated['cursorSize'],
        2.5,
        reason: 'Migration must preserve fields that already exist',
      );
    });

    test('parsing a JSON with explicit schemaVersion=1 routes through '
        'the migration chain (covers projects written by an older build)', () {
      final v1Explicit = <String, dynamic>{
        'schemaVersion': 1,
        'zoomRegions': const <Map<String, dynamic>>[],
        'cursorSize': 3.0,
      };

      final state = EditorProjectState.fromJson(
        v1Explicit,
        videoDuration: const Duration(seconds: 60),
      );
      expect(state.cursorSize, 3.0);
    });

    test('v2 → v3: flat zoomRegions list is folded onto a single zoom '
        'track inside a new timeline container, lossless', () {
      // A v2 sidecar (post-migration-switchboard, pre-timeline) keeps
      // zoom regions at the top level. Loading it must preserve every
      // region under timeline.zoomTracks[0].regions without any field
      // loss — playback should look identical to before.
      final v2Json = <String, dynamic>{
        'schemaVersion': 2,
        'zoomRegions': [
          {
            'rect': {'left': 0.1, 'top': 0.2, 'width': 0.3, 'height': 0.4},
            'startTimeMicros': 250,
            'durationMicros': 2000,
            'zoomLevel': 1.7,
          },
          {
            'rect': {'left': 0.5, 'top': 0.5, 'width': 0.2, 'height': 0.2},
            'startTimeMicros': 3000,
            'durationMicros': 1500,
            'zoomLevel': 2.2,
          },
        ],
        'cursorSize': 2.5,
      };

      final migrated = migrateEditorProjectJson(
        v2Json,
        videoDuration: const Duration(seconds: 60),
      );
      expect(
        migrated['schemaVersion'],
        EditorProjectState.currentSchemaVersion,
      );
      expect(
        migrated.containsKey('zoomRegions'),
        isFalse,
        reason: 'top-level zoomRegions must be removed in v3',
      );
      expect(migrated['timeline'], isA<Map<String, dynamic>>());
      expect((migrated['timeline'] as Map)['zoomTracks'], hasLength(1));

      // Parse through fromJson — every region should survive, accessible
      // via the convenience shim.
      final state = EditorProjectState.fromJson(
        v2Json,
        videoDuration: const Duration(seconds: 60),
      );
      expect(state.zoomRegions, hasLength(2));
      expect(state.zoomRegions.first.zoomLevel, 1.7);
      expect(state.zoomRegions.last.zoomLevel, 2.2);
      expect(
        state.cursorSize,
        2.5,
        reason: 'unrelated fields must pass through migration unchanged',
      );
      expect(state.timeline.zoomTracks, hasLength(1));
    });

    test('v2 → v3: missing zoomRegions yields an empty track, not crash', () {
      final v2Json = <String, dynamic>{
        'schemaVersion': 2,
        'cursorSize': 1.0,
        // No zoomRegions key (hand-edited / partial sidecar).
      };
      final state = EditorProjectState.fromJson(
        v2Json,
        videoDuration: const Duration(seconds: 60),
      );
      expect(state.timeline.zoomTracks, hasLength(1));
      expect(state.zoomRegions, isEmpty);
    });

    test('v1 → v3 chains through both steps in order', () {
      final v1Json = <String, dynamic>{
        // No schemaVersion → v1
        'zoomRegions': [
          {
            'rect': {'left': 0.0, 'top': 0.0, 'width': 0.5, 'height': 0.5},
            'startTimeMicros': 0,
            'durationMicros': 1000,
            'zoomLevel': 1.3,
          },
        ],
      };
      final state = EditorProjectState.fromJson(
        v1Json,
        videoDuration: const Duration(seconds: 60),
      );
      // Both steps ran: schemaVersion marker added (v1→v2), then regions
      // moved into the timeline (v2→v3).
      expect(state.zoomRegions, hasLength(1));
      expect(state.zoomRegions.first.zoomLevel, 1.3);
      expect(state.timeline, isA<Timeline>());
    });

    test('v10 → v11 preserves legacy follow spring frequency', () {
      final v10 =
          EditorProjectState.defaults()
              .copyWith(
                zoomRegions: [
                  ZoomRegion(
                    rect: const Rect.fromLTWH(100, 100, 200, 200),
                    startTime: Duration.zero,
                    duration: const Duration(seconds: 2),
                    zoomLevel: 2,
                    followDuration: const Duration(milliseconds: 400),
                  ),
                ],
              )
              .toJson()
            ..['schemaVersion'] = 10;

      final state = EditorProjectState.fromJson(
        v10,
        videoDuration: const Duration(seconds: 2),
      );

      expect(state.zoomRegions.single.followDuration.inMicroseconds, 948773);
    });

    test('v10 → v11 migrates the omitted legacy follow default', () {
      final v10 =
          EditorProjectState.defaults()
              .copyWith(
                zoomRegions: [
                  ZoomRegion(
                    rect: const Rect.fromLTWH(100, 100, 200, 200),
                    startTime: Duration.zero,
                    duration: const Duration(seconds: 2),
                    zoomLevel: 2,
                  ),
                ],
              )
              .toJson()
            ..['schemaVersion'] = 10;
      final timeline = v10['timeline'] as Map<String, dynamic>;
      final tracks = timeline['zoomTracks'] as List<dynamic>;
      final regions =
          (tracks.single as Map<String, dynamic>)['regions'] as List<dynamic>;
      (regions.single as Map<String, dynamic>).remove('followDurationMicros');

      final state = EditorProjectState.fromJson(
        v10,
        videoDuration: const Duration(seconds: 2),
      );

      expect(state.zoomRegions.single.followDuration.inMicroseconds, 2016142);
    });
  });
}
