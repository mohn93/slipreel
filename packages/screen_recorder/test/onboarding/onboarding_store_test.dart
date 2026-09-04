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
    expect(await store.loadStep(), OnboardingStep.welcome);
  });

  test('saveStep persists the current onboarding page', () async {
    final store = OnboardingStore();
    await store.saveStep(OnboardingStep.permissions);

    expect(await OnboardingStore().loadStep(), OnboardingStep.permissions);
  });

  test('markComplete persists and clears partial progress', () async {
    final store = OnboardingStore();
    await store.saveStep(OnboardingStep.permissions);
    await store.markComplete();

    expect(await store.load(), isTrue);
    expect(await store.loadStep(), OnboardingStep.welcome);
  });

  test('reset clears the completion flag and partial progress', () async {
    final store = OnboardingStore();
    await store.markComplete();
    await store.saveStep(OnboardingStep.ready);
    await store.reset();

    expect(await store.load(), isFalse);
    expect(await store.loadStep(), OnboardingStep.welcome);
  });
}
