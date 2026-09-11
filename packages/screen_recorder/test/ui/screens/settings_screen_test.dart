import 'package:screen_recorder/update/updater_backend.dart';
import 'package:screen_recorder/update/updater_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/licensing/trial_exports.dart';
import 'package:screen_recorder/state/global_preferences_controller.dart';
import 'package:screen_recorder/state/global_preferences_store.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/state/recording_settings_controller.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;

/// Minimal platform stub — same pattern as test/state/sleep_observer_test.dart.
class _FakePlatform extends ScreenRecorderPlatform {}
class _UpdateBackend implements UpdaterBackend {
  int checks = 0;
  @override
  Future<void> setFeedURL(String url) async {}
  @override
  Future<void> setScheduledCheckInterval(int seconds) async {}
  @override
  Future<void> checkForUpdates({bool inBackground = false}) async { checks++; }
}

Widget _app(Widget child, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          // AppPalette.midnight is the real default constant in app_palette.dart.
          extensions: [AppPalette.midnight],
        ),
        home: child,
      ),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    ScreenRecorderPlatform.instance = _FakePlatform();
  });

  final overrides = <Override>[
    recordingSettingsControllerProvider.overrideWith((ref) =>
        RecordingSettingsController(
            store: RecordingSettingsStore(path: '/tmp/x_rec.json'),
            initial: RecordingSettings.defaults)),
    globalPreferencesControllerProvider.overrideWith((ref) =>
        GlobalPreferencesController(
            store: GlobalPreferencesStore(path: '/tmp/x_glob.json'),
            initial: GlobalPreferences.defaults)),
    permissionsControllerProvider.overrideWith(
        (ref) => PermissionsController(ScreenRecorderPlatform.instance)),
  ];

  testWidgets('shows global sections, not frame styling or alert demo',
      (tester) async {
    await tester.pumpWidget(_app(const SettingsScreen(), overrides));
    await tester.pump();

    expect(find.text('Recording'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Default save location'), findsOneWidget);
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    expect(find.text('Alert demo'), findsNothing);
    expect(find.text('Padding'), findsNothing);
    expect(find.text('Corner Radius'), findsNothing);
    expect(find.text('Background Color'), findsNothing);
  });

  testWidgets('save location shows the Ask-each-time default when unset',
      (tester) async {
    await tester.pumpWidget(_app(const SettingsScreen(), overrides));
    await tester.pump();
    expect(find.textContaining('Ask each time'), findsOneWidget);
  });

  // ---- Account section -----------------------------------------------------

  EntitlementClaims claims({
    required String plan,
    String status = 'active',
    DateTime? updatesUntil,
  }) =>
      EntitlementClaims(
        sub: 'u1',
        plan: plan,
        exportEntitled: plan != 'free',
        status: status,
        updatesUntil: updatesUntil,
        deviceId: 'dev1',
        seatLimit: 2,
        issuedAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2099, 1, 1),
      );

  List<Override> withEntitlement(EntitlementState state) =>
      [...overrides, entitlementProvider.overrideWithValue(state)];

  testWidgets('one-time updates require compatibility confirmation', (tester) async {
    final backend = _UpdateBackend();
    await tester.pumpWidget(_app(const SettingsScreen(), [
      ...withEntitlement(EntitlementLoaded(claims(plan: 'onetime',
          updatesUntil: DateTime.utc(2027, 1, 1)))),
      updaterServiceProvider.overrideWithValue(UpdaterService(backend)),
    ]));
    await tester.pump();
    await tester.ensureVisible(find.text('Check for updates'));
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.text('Check license compatibility'), findsOneWidget);
    expect(find.textContaining('2027-01-01 (UTC)'), findsOneWidget);
    expect(backend.checks, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.checks, 0);
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Check for updates'));
    await tester.pumpAndSettle();
    expect(backend.checks, 1);
  });

  testWidgets('hides the Account section when licensing is not wired',
      (tester) async {
    await tester.pumpWidget(_app(const SettingsScreen(), overrides));
    await tester.pump();
    expect(find.text('Account'), findsNothing);
  });

  testWidgets('signed out shows a Sign in prompt', (tester) async {
    await tester.pumpWidget(
        _app(const SettingsScreen(), withEntitlement(const EntitlementSignedOut())));
    await tester.pump();
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Not signed in'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('active subscription shows Pro plan and Manage account',
      (tester) async {
    await tester.pumpWidget(_app(const SettingsScreen(),
        withEntitlement(EntitlementLoaded(claims(plan: 'subscription')))));
    await tester.pump();
    expect(find.text('Pro — Monthly'), findsOneWidget);
    expect(find.textContaining('unlimited exports'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Manage account'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Upgrade'), findsNothing);
  });

  testWidgets('free plan shows no license and an Upgrade action',
      (tester) async {
    await tester.pumpWidget(_app(const SettingsScreen(),
        withEntitlement(EntitlementLoaded(claims(plan: 'free', status: 'none')))));
    await tester.pump();
    expect(find.text('No active license'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Upgrade'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Manage account'), findsOneWidget);
  });

  testWidgets('not-entitled account shows the remaining free-export count',
      (tester) async {
    await tester.pumpWidget(_app(
        const SettingsScreen(),
        [
          ...withEntitlement(EntitlementLoaded(claims(plan: 'free', status: 'none'))),
          trialExportsRemainingProvider.overrideWith((ref) async => 2),
        ]));
    await tester.pump(); // resolve the FutureProvider
    expect(find.text('2 of ${TrialExports.limit} free exports left'),
        findsOneWidget);
  });

  testWidgets('entitled account does not show a free-export count',
      (tester) async {
    await tester.pumpWidget(_app(
        const SettingsScreen(),
        [
          ...withEntitlement(EntitlementLoaded(claims(plan: 'subscription'))),
          trialExportsRemainingProvider.overrideWith((ref) async => 2),
        ]));
    await tester.pump();
    expect(find.textContaining('free exports left'), findsNothing);
  });
}
