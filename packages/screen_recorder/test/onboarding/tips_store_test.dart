import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('load returns empty set on fresh install', () async {
    final store = TipsStore();
    expect(await store.load(), isEmpty);
  });

  test('markSeen + load round-trips', () async {
    final store = TipsStore();
    await store.markSeen('tip.bar.modePicker');
    await store.markSeen('tip.editor.trim');
    final loaded = await store.load();
    expect(loaded, {'tip.bar.modePicker', 'tip.editor.trim'});
  });

  test('clearAll wipes the set', () async {
    final store = TipsStore();
    await store.markSeen('tip.x');
    await store.clearAll();
    expect(await store.load(), isEmpty);
  });
}
