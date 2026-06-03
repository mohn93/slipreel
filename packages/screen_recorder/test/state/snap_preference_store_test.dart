// packages/screen_recorder/test/state/snap_preference_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/state/snap_preference_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SnapPreferenceStore', () {
    test('load() defaults to true when no value is stored', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      expect(store.load(), isTrue);
    });

    test('load() returns the stored value when present', () async {
      SharedPreferences.setMockInitialValues({'slipreel.snap_enabled': false});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      expect(store.load(), isFalse);
    });

    test('save(false) persists; subsequent load() returns false', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      await store.save(false);
      expect(store.load(), isFalse);
    });

    test('save(true) round-trips after save(false)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      await store.save(false);
      await store.save(true);
      expect(store.load(), isTrue);
    });
  });
}
