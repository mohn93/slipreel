import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/state/export_settings_store.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('exp_settings_store_test');
  });

  tearDown(() {
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  group('ExportSettingsStore', () {
    test('load returns defaults when file is missing', () async {
      final filePath = '${tmpDir.path}/settings.json';
      final store = ExportSettingsStore(filePath: filePath);
      final settings = await store.load();
      expect(settings, ExportSettings.defaults());
    });

    test('save then load round-trips', () async {
      final filePath = '${tmpDir.path}/settings.json';
      final store = ExportSettingsStore(filePath: filePath);

      final original = ExportSettings(
        format: ExportFormat.gif,
        resolution: ExportResolution.r4k,
        compression: CompressionTier.studio,
        frameRate: 60,
        destination: ExportDestination.clipboard,
        title: 'Test Video',
        isPrivate: true,
      );

      await store.save(original);
      expect(File(filePath).existsSync(), isTrue);

      final restored = await store.load();
      expect(restored, original);
    });

    test('load returns defaults + logs warning on corrupt JSON', () async {
      final filePath = '${tmpDir.path}/settings.json';
      File(filePath).writeAsStringSync('not json {{{');

      final store = ExportSettingsStore(filePath: filePath);
      final settings = await store.load();
      expect(settings, ExportSettings.defaults());
    });

    test('load throws FormatException on future schema version', () async {
      final filePath = '${tmpDir.path}/settings.json';
      File(filePath).writeAsStringSync(
        '{"schemaVersion": 99, "settings": {"format": "mp4", "resolution": "r1080p", "compression": "web", "frameRate": 30, "destination": "file"}}',
      );

      final store = ExportSettingsStore(filePath: filePath);
      expect(
        () => store.load(),
        throwsA(isA<FormatException>()),
      );
    });

    test('save then load round-trips after overwriting future schema', () async {
      final filePath = '${tmpDir.path}/settings.json';
      File(filePath).writeAsStringSync(
        '{"schemaVersion": 99, "settings": {}}',
      );

      final store = ExportSettingsStore(filePath: filePath);
      final newSettings = ExportSettings(
        format: ExportFormat.mp4,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.socialMedia,
        frameRate: 50,
        destination: ExportDestination.shareableLink,
        isPrivate: false,
      );

      await store.save(newSettings);
      final restored = await store.load();
      expect(restored, newSettings);
    });

    test('concurrent saves are serialized in submission order', () async {
      final store = ExportSettingsStore(filePath: '${tmpDir.path}/settings.json');
      final completionOrder = <int>[];

      final futures = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(
          store.save(
            ExportSettings.defaults().copyWith(frameRate: 30 + (i % 60)),
          ).then((_) => completionOrder.add(i)),
        );
      }
      await Future.wait(futures);

      // Saves were submitted 0..9; the queue must complete them in
      // submission order, not interleaved or out-of-order.
      expect(completionOrder, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('save cleans up tmp file on success', () async {
      final filePath = '${tmpDir.path}/settings.json';
      final store = ExportSettingsStore(filePath: filePath);
      final settings = ExportSettings.defaults();

      await store.save(settings);

      expect(File(filePath).existsSync(), isTrue);
      final tmpFile = File('$filePath.tmp');
      expect(tmpFile.existsSync(), isFalse);
    });

    test('save overwrites a stale .tmp file from a prior crash', () async {
      final filePath = '${tmpDir.path}/settings.json';
      // Pre-create a stale tmp file as if a previous run crashed mid-write.
      await File('$filePath.tmp').writeAsString('garbage from a crash');

      final store = ExportSettingsStore(filePath: filePath);
      await store.save(ExportSettings.defaults());

      // Tmp file is gone; target file is valid.
      expect(File('$filePath.tmp').existsSync(), isFalse);
      expect(File(filePath).existsSync(), isTrue);
      final reloaded = await store.load();
      expect(reloaded, ExportSettings.defaults());
    });

    test('load returns defaults when schemaVersion is missing', () async {
      final filePath = '${tmpDir.path}/settings.json';
      await File(filePath).writeAsString(
        jsonEncode({
          'settings': {
            'format': 'mp4',
            'resolution': 'r1080p',
            'compression': 'web',
            'frameRate': 30,
            'destination': 'file',
          }
        }),
      );

      final store = ExportSettingsStore(filePath: filePath);
      expect(await store.load(), ExportSettings.defaults());
    });

    test('load returns defaults when schemaVersion is older than supported',
        () async {
      final filePath = '${tmpDir.path}/settings.json';
      await File(filePath).writeAsString(
        jsonEncode({
          'schemaVersion': 0,
          'settings': {
            'format': 'mp4',
            'resolution': 'r1080p',
            'compression': 'web',
            'frameRate': 30,
            'destination': 'file',
          }
        }),
      );

      final store = ExportSettingsStore(filePath: filePath);
      expect(await store.load(), ExportSettings.defaults());
    });
  });
}
