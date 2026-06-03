// packages/screen_recorder/test/state/snap_preference_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/state/snap_preference_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SnapPreferenceStore> store([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    return SnapPreferenceStore(await SharedPreferences.getInstance());
  }

  group('SnapPreferenceController', () {
    test('constructs with the given initial value', () async {
      final c = SnapPreferenceController(store: await store(), initial: false);
      expect(c.state, isFalse);
    });

    test('setEnabled(true) updates state to true', () async {
      final c = SnapPreferenceController(store: await store(), initial: false);
      c.setEnabled(true);
      expect(c.state, isTrue);
    });

    test('setEnabled persists to the store', () async {
      final s = await store();
      final c = SnapPreferenceController(store: s, initial: true);
      c.setEnabled(false);
      // The save is unawaited; pump the microtask queue so the SharedPreferences
      // write completes before we re-read.
      await Future<void>.delayed(Duration.zero);
      expect(s.load(), isFalse);
    });

    test('round-trips true -> false -> true', () async {
      final c = SnapPreferenceController(store: await store(), initial: true);
      c.setEnabled(false);
      expect(c.state, isFalse);
      c.setEnabled(true);
      expect(c.state, isTrue);
    });
  });
}
