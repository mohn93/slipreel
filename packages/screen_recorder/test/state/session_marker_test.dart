// packages/screen_recorder/test/state/session_marker_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/session_marker.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('session_marker_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  String tmpPath() => '${tmp.path}/current_sessions.json';

  SessionMarker make(String id) => SessionMarker(
        id: id,
        videoPath: '${tmp.path}/$id.mp4',
        cursorNdjsonPath: '${tmp.path}/$id.cursor.ndjson',
        startedAt: DateTime.utc(2026, 5, 29, 15, 30),
        width: 1920,
        height: 1080,
        fps: 60,
      );

  test('load on fresh disk returns empty list', () async {
    final store = SessionMarkerStore(path: tmpPath());
    expect(await store.load(), isEmpty);
  });

  test('add then load round-trips a single marker', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.first.id, 's1');
    expect(loaded.first.width, 1920);
    expect(loaded.first.fps, 60);
  });

  test('add multiple markers preserves all', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    await store.add(make('s2'));
    expect((await store.load()).map((m) => m.id), ['s1', 's2']);
  });

  test('remove deletes the matching marker only', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    await store.add(make('s2'));
    await store.remove('s1');
    expect((await store.load()).map((m) => m.id), ['s2']);
  });

  test('remove of missing id is a no-op', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    await store.remove('does-not-exist');
    expect((await store.load()).map((m) => m.id), ['s1']);
  });

  test('corrupt JSON falls back to empty (file is left for the next add to overwrite)', () async {
    await File(tmpPath()).writeAsString('{ garbage');
    final store = SessionMarkerStore(path: tmpPath());
    expect(await store.load(), isEmpty);
  });

  test('writes via .tmp + rename so the canonical file is never half-written', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    // Confirm the tmp file was cleaned up after rename.
    expect(File('${tmpPath()}.tmp').existsSync(), isFalse);
  });
}
