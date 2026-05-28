import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('shouldShow returns true for an unseen id', () async {
    final c = TipsController(TipsStore());
    await c.load();
    expect(c.shouldShow(TipId.barModePicker), isTrue);
  });

  test('markSeen flips shouldShow to false', () async {
    final c = TipsController(TipsStore());
    await c.load();
    await c.markSeen(TipId.barModePicker);
    expect(c.shouldShow(TipId.barModePicker), isFalse);
  });

  test('only one tip can be active at a time', () async {
    final c = TipsController(TipsStore());
    await c.load();
    expect(c.tryClaim(TipId.barModePicker), isTrue);
    expect(c.tryClaim(TipId.editorTrimHandles), isFalse);
    c.release(TipId.barModePicker);
    expect(c.tryClaim(TipId.editorTrimHandles), isTrue);
  });

  test('copyFor returns the registered message', () {
    final c = TipsController(TipsStore());
    expect(c.copyFor(TipId.barModePicker), isNotEmpty);
  });
}
