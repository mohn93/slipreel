import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/onboarding_store.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/ui/screens/onboarding/onboarding_screen.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubPermissionsController extends StateNotifier<PermissionsSnapshot>
    implements PermissionsController {
  _StubPermissionsController() : super(PermissionsSnapshot.initial);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<PermissionStatus> request(PermissionKind kind) async =>
      state.byKind[kind] ?? PermissionStatus.unsupported;
}

class _StubWindowChrome implements WindowChrome {
  @override
  Future<void> setMode(WindowMode mode) async {}

  @override
  Future<String?> showGearMenu() async => null;

  @override
  Future<void> startWindowDrag() async {}

  @override
  Future<void> setBarSize(double width, double height) async {}
}

Future<void> _pumpOnboarding(
  WidgetTester tester, {
  required OnboardingStore store,
  OnboardingStep initialStep = OnboardingStep.welcome,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        onboardingStoreProvider.overrideWithValue(store),
        permissionsControllerProvider.overrideWith(
          (ref) => _StubPermissionsController(),
        ),
        windowChromeProvider.overrideWithValue(_StubWindowChrome()),
      ],
      child: MaterialApp(home: OnboardingScreen(initialStep: initialStep)),
    ),
  );
  await tester.pump();
}

Future<void> _tearDownOnboarding(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('restores the saved permissions step after relaunch',
      (tester) async {
    final store = OnboardingStore();
    await store.saveStep(OnboardingStep.permissions);

    await _pumpOnboarding(
      tester,
      store: store,
      initialStep: await store.loadStep(),
    );

    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Welcome to Slipreel'), findsNothing);
    await _tearDownOnboarding(tester);
  });

  testWidgets('persists each step before advancing to it', (tester) async {
    final store = OnboardingStore();
    await _pumpOnboarding(tester, store: store);

    await tester.tap(find.widgetWithText(FilledButton, 'Get started'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(await store.loadStep(), OnboardingStep.features);

    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(await store.loadStep(), OnboardingStep.permissions);

    await _tearDownOnboarding(tester);
  });
}
