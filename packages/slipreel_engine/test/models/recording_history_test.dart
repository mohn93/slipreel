import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:slipreel_engine/models/recording_history.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RecordingHistoryEntry', () {
    test('JSON round-trip preserves all fields', () {
      final original = RecordingHistoryEntry(
        videoPath: '/Users/x/recordings/a.mp4',
        recordedAt: DateTime(2026, 04, 30, 14, 30, 5),
        widthPx: 1920,
        heightPx: 1080,
        fps: 60,
      );
      final round =
          RecordingHistoryEntry.fromJson(original.toJson());
      expect(round, equals(original));
    });
  });

  group('RecordingHistoryStore', () {
    test('append puts new entry at the front', () async {
      final store = RecordingHistoryStore();
      await store.append(_entry('/a.mp4', DateTime(2026, 1, 1)));
      await store.append(_entry('/b.mp4', DateTime(2026, 1, 2)));

      final list = await store.load();
      expect(list.map((e) => e.videoPath).toList(),
          equals(['/b.mp4', '/a.mp4']));
    });

    test('append dedupes by path, keeping the latest entry at the front',
        () async {
      final store = RecordingHistoryStore();
      await store.append(_entry('/a.mp4', DateTime(2026, 1, 1)));
      await store.append(_entry('/b.mp4', DateTime(2026, 1, 2)));
      await store.append(_entry('/a.mp4', DateTime(2026, 1, 3)));

      final list = await store.load();
      expect(list.length, 2);
      expect(list.first.videoPath, '/a.mp4');
      expect(list.first.recordedAt, DateTime(2026, 1, 3));
      expect(list[1].videoPath, '/b.mp4');
    });

    test('append caps at maxEntries (100)', () async {
      final store = RecordingHistoryStore();
      // Insert 105 unique entries; oldest 5 should be dropped.
      for (var i = 0; i < 105; i++) {
        await store.append(_entry('/v$i.mp4', DateTime(2026, 1, 1, 0, i)));
      }
      final list = await store.load();
      expect(list.length, RecordingHistoryStore.maxEntries);
      // Most recent insertion is /v104.mp4 → at the front.
      expect(list.first.videoPath, '/v104.mp4');
      // Anything older than /v5 should have been dropped.
      expect(list.any((e) => e.videoPath == '/v0.mp4'), isFalse);
      expect(list.any((e) => e.videoPath == '/v4.mp4'), isFalse);
    });

    test('removeByPath drops the matching entry, no-op otherwise', () async {
      final store = RecordingHistoryStore();
      await store.append(_entry('/a.mp4', DateTime(2026, 1, 1)));
      await store.append(_entry('/b.mp4', DateTime(2026, 1, 2)));

      final after = await store.removeByPath('/a.mp4');
      expect(after.map((e) => e.videoPath).toList(), ['/b.mp4']);

      // No-op for unknown path.
      final unchanged = await store.removeByPath('/missing.mp4');
      expect(unchanged.map((e) => e.videoPath).toList(), ['/b.mp4']);
    });

    test('load returns empty list on missing or malformed JSON', () async {
      // Missing.
      var list = await RecordingHistoryStore().load();
      expect(list, isEmpty);

      // Malformed.
      SharedPreferences.setMockInitialValues({
        'recording_history': '{not json',
      });
      list = await RecordingHistoryStore().load();
      expect(list, isEmpty);
    });
  });
}

RecordingHistoryEntry _entry(String path, DateTime when) {
  return RecordingHistoryEntry(
    videoPath: path,
    recordedAt: when,
    widthPx: 1280,
    heightPx: 720,
    fps: 30,
  );
}
