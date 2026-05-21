import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  group('EditorProjectState.fromJson schema migration', () {
    test(
      'JSON missing schemaVersion (legacy v1 file) parses via the '
      'migration chain into a valid v2 state',
      () {
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

        final state = EditorProjectState.fromJson(v1Json);

        expect(state.cursorSize, 1.5);
        expect(state.motionBlur, 0.3);
        expect(state.zoomRegions, isEmpty);
        // Fields that didn't exist in v1 (or weren't in this fixture)
        // come from defaults.
        expect(state.cursorDelay.inMilliseconds, isPositive);
      },
    );

    test('JSON with schemaVersion=2 passes through unchanged', () {
      final v2Json = EditorProjectState.defaults().toJson();
      // Sanity: defaults' toJson emits current schemaVersion.
      expect(v2Json['schemaVersion'], EditorProjectState.currentSchemaVersion);

      // Round-trip parse.
      final state = EditorProjectState.fromJson(v2Json);
      expect(state.cursorSize, EditorProjectState.defaults().cursorSize);
    });

    test(
      'JSON with schemaVersion newer than currentSchemaVersion throws',
      () {
        // A future build wrote a sidecar this build doesn't understand.
        // The loader must refuse to guess — silently parsing with
        // unknown shape would corrupt the user's project.
        final futureJson = <String, dynamic>{
          'schemaVersion': EditorProjectState.currentSchemaVersion + 5,
          'zoomRegions': const <Map<String, dynamic>>[],
        };

        expect(
          () => EditorProjectState.fromJson(futureJson),
          throwsFormatException,
        );
      },
    );

    test(
      'migration chain is composable: each step consumes vN and '
      'produces vN+1',
      () {
        // Direct unit test of the migration pipeline so future migrations
        // can be added with confidence the chain composes.
        final v1Json = <String, dynamic>{
          'cursorSize': 2.5,
          // No schemaVersion → v1
        };
        final migrated = migrateEditorProjectJson(v1Json);
        expect(
          migrated['schemaVersion'],
          EditorProjectState.currentSchemaVersion,
          reason: 'After migration, the JSON must declare the current '
              'schema version so downstream readers know what they have',
        );
        expect(migrated['cursorSize'], 2.5,
            reason: 'Migration must preserve fields that already exist');
      },
    );

    test(
      'parsing a JSON with explicit schemaVersion=1 routes through '
      'the migration chain (covers projects written by an older build)',
      () {
        final v1Explicit = <String, dynamic>{
          'schemaVersion': 1,
          'zoomRegions': const <Map<String, dynamic>>[],
          'cursorSize': 3.0,
        };

        final state = EditorProjectState.fromJson(v1Explicit);
        expect(state.cursorSize, 3.0);
      },
    );
  });
}
