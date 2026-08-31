import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/state/global_preferences_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('globalprefs_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String path() => p.join(tmp.path, 'global_preferences.json');

  test('load() on a missing file returns defaults (null save location)', () async {
    final store = GlobalPreferencesStore(path: path());
    final loaded = await store.load();
    expect(loaded.defaultSaveLocation, isNull);
  });

  test('save() then load() round-trips the save location', () async {
    final store = GlobalPreferencesStore(path: path());
    await store.save(const GlobalPreferences(defaultSaveLocation: '/Users/me/Movies'));
    final loaded = await store.load();
    expect(loaded.defaultSaveLocation, '/Users/me/Movies');
  });

  test('saving null clears the save location', () async {
    final store = GlobalPreferencesStore(path: path());
    await store.save(const GlobalPreferences(defaultSaveLocation: '/x'));
    await store.save(const GlobalPreferences(defaultSaveLocation: null));
    expect((await store.load()).defaultSaveLocation, isNull);
  });

  test('malformed JSON falls back to defaults', () async {
    File(path()).writeAsStringSync('{ not json');
    final store = GlobalPreferencesStore(path: path());
    expect((await store.load()).defaultSaveLocation, isNull);
  });

  test('copyWith with clearSaveLocation:true nulls the field', () {
    const a = GlobalPreferences(defaultSaveLocation: '/x');
    expect(a.copyWith(clearSaveLocation: true).defaultSaveLocation, isNull);
    expect(a.copyWith().defaultSaveLocation, '/x');
  });

  test('shareAnalytics defaults on, and an older prefs file (absent) reads on',
      () async {
    expect(GlobalPreferences.defaults.shareAnalytics, isTrue);
    // A prefs file written before the field existed.
    File(path()).writeAsStringSync('{"defaultSaveLocation":"/x"}');
    expect((await GlobalPreferencesStore(path: path()).load()).shareAnalytics,
        isTrue);
  });

  test('shareAnalytics round-trips false', () async {
    final store = GlobalPreferencesStore(path: path());
    await store.save(const GlobalPreferences(shareAnalytics: false));
    expect((await store.load()).shareAnalytics, isFalse);
  });
}
