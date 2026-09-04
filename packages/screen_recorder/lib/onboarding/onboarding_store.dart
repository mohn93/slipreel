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
    final savedName = prefs.getString(_stepKey);
    for (final step in OnboardingStep.values) {
      if (step.name == savedName) return step;
    }
    return OnboardingStep.welcome;
  }

  Future<void> saveStep(OnboardingStep step) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_stepKey, step.name);
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
