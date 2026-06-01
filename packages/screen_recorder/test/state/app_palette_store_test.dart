import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('app_palette_store_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('AppPaletteStore', () {
    test('save then load round-trips each PaletteId', () async {
      for (final id in PaletteId.values) {
        final store = AppPaletteStore(path: p.join(tmp.path, 'p_$id.json'));
        await store.save(id);
        final loaded = await store.load();
        expect(loaded, id, reason: 'round-trip for $id');
      }
    });

    test('load returns null when the file does not exist', () async {
      final store = AppPaletteStore(path: p.join(tmp.path, 'missing.json'));
      expect(await store.load(), isNull);
    });

    test('load returns null for an unknown paletteId string', () async {
      final file = File(p.join(tmp.path, 'unknown.json'));
      await file.writeAsString('{"paletteId": "neon-pink"}');
      final store = AppPaletteStore(path: file.path);
      expect(await store.load(), isNull);
    });

    test('load returns null for invalid JSON', () async {
      final file = File(p.join(tmp.path, 'corrupt.json'));
      await file.writeAsString('not json at all');
      final store = AppPaletteStore(path: file.path);
      expect(await store.load(), isNull);
    });

    test('save creates parent directories as needed', () async {
      final store = AppPaletteStore(
        path: p.join(tmp.path, 'sub', 'dir', 'palette.json'),
      );
      await store.save(PaletteId.obsidian);
      expect(await store.load(), PaletteId.obsidian);
    });
  });
}
