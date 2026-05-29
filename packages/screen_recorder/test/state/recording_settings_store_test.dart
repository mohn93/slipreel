// packages/screen_recorder/test/state/recording_settings_store_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rec_settings_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('load returns default 3 on fresh install', () async {
    final store = RecordingSettingsStore(path: '${tmp.path}/recording_settings.json');
    final settings = await store.load();
    expect(settings.countdownSeconds, 3);
  });

  test('save + load round-trips countdownSeconds', () async {
    final store = RecordingSettingsStore(path: '${tmp.path}/recording_settings.json');
    await store.save(const RecordingSettings(countdownSeconds: 5));
    final settings = await store.load();
    expect(settings.countdownSeconds, 5);
  });

  test('corrupt JSON falls back to defaults', () async {
    final path = '${tmp.path}/recording_settings.json';
    await File(path).writeAsString('{ garbage');
    final store = RecordingSettingsStore(path: path);
    final settings = await store.load();
    expect(settings.countdownSeconds, 3);
  });

  test('rejects invalid countdownSeconds values (defaults to 3)', () async {
    final path = '${tmp.path}/recording_settings.json';
    await File(path).writeAsString('{"countdownSeconds": 99}');
    final store = RecordingSettingsStore(path: path);
    final settings = await store.load();
    expect(settings.countdownSeconds, 3);
  });
}
