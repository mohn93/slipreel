import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum OnboardingStep { welcome, features, permissions, ready }

class OnboardingStore {
  static const _completeKey = 'slipreel.onboarding_complete';
  static const _stepKey = 'slipreel.onboarding_step';

  Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_completeKey) ?? false;
  }

  Future<OnboardingStep> loadStep() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_stepKey);
    if (index == null || index < 0 || index >= OnboardingStep.values.length) {
      return OnboardingStep.welcome;
    }
    return OnboardingStep.values[index];
  }

  Future<void> saveStep(OnboardingStep step) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_stepKey, step.index);
  }

  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_completeKey, true);
    await prefs.remove(_stepKey);
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_completeKey);
    await prefs.remove(_stepKey);
  }
}

final onboardingStoreProvider = Provider<OnboardingStore>(
  (ref) => throw UnimplementedError(
    'Override onboardingStoreProvider in main() with a real instance',
  ),
);
