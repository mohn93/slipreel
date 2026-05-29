import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/onboarding_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load returns false on fresh install', () async {
    final store = OnboardingStore();
    expect(await store.load(), isFalse);
  });

  test('markComplete persists; subsequent load returns true', () async {
    final store = OnboardingStore();
    await store.markComplete();
    expect(await store.load(), isTrue);
  });

  test('reset returns flag to false', () async {
    final store = OnboardingStore();
    await store.markComplete();
    await store.reset();
    expect(await store.load(), isFalse);
  });
}
