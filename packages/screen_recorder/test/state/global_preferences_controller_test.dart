import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/state/global_preferences_controller.dart';
import 'package:screen_recorder/state/global_preferences_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('globalprefs_ctrl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  GlobalPreferencesController make() => GlobalPreferencesController(
        store: GlobalPreferencesStore(path: p.join(tmp.path, 'g.json')),
        initial: GlobalPreferences.defaults,
      );

  test('setDefaultSaveLocation updates state and persists', () async {
    final c = make();
    await c.setDefaultSaveLocation('/Users/me/Clips');
    expect(c.state.defaultSaveLocation, '/Users/me/Clips');
    expect(await c.store.load(), isA<GlobalPreferences>()
        .having((g) => g.defaultSaveLocation, 'saved', '/Users/me/Clips'));
  });

  test('setDefaultSaveLocation(null) clears it', () async {
    final c = make();
    await c.setDefaultSaveLocation('/x');
    await c.setDefaultSaveLocation(null);
    expect(c.state.defaultSaveLocation, isNull);
    expect((await c.store.load()).defaultSaveLocation, isNull);
  });
}
