import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/store/native_account.dart';
import 'package:screen_recorder/store/store_account_card.dart';
import 'package:screen_recorder/state/global_preferences_controller.dart';
import 'package:screen_recorder/state/global_preferences_store.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/state/recording_settings_controller.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;
import 'store_paywall_test.dart'
    show FakeLicensing, FakeStore, FakeAccount, paid;

class _Platform extends ScreenRecorderPlatform {}

void main() {
  setUp(() => ScreenRecorderPlatform.instance = _Platform());
  Future<void> host(
    WidgetTester tester,
    FakeLicensing c,
    FakeAccount a, {
    bool full = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          licensingControllerProvider.overrideWith((ref) => c),
          nativeAccountProvider.overrideWith((ref) => a),
          recordingSettingsControllerProvider.overrideWith(
            (ref) => RecordingSettingsController(
              store: RecordingSettingsStore(
                path: '/tmp/slipreel-ui-recording.json',
              ),
              initial: RecordingSettings.defaults,
            ),
          ),
          globalPreferencesControllerProvider.overrideWith(
            (ref) => GlobalPreferencesController(
              store: GlobalPreferencesStore(
                path: '/tmp/slipreel-ui-preferences.json',
              ),
              initial: GlobalPreferences.defaults,
            ),
          ),
          permissionsControllerProvider.overrideWith(
            (ref) => PermissionsController(ScreenRecorderPlatform.instance),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(extensions: [AppPalette.midnight]),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: const Key('capture'),
            child: full
                ? const SettingsScreen()
                : Scaffold(
                    body: Consumer(
                      builder: (context, ref, _) => StoreAccountCard(
                        state:
                            ref.watch(entitlementProvider)
                                as EntitlementAppStore,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('paid settings show account and management without upsell', (
    tester,
  ) async {
    final c = FakeLicensing(FakeStore())..setAccess(paid());
    await host(tester, c, FakeAccount(c));
    expect(find.text('Pro · Yearly'), findsOneWidget);
    expect(find.text('Manage subscription'), findsOneWidget);
    expect(find.text('Unlock unlimited exports'), findsNothing);
    expect(find.text('App Store subscription'), findsNothing);
    expect(find.text('qa@example.com'), findsOneWidget);
  });
  testWidgets(
    'free settings offers benefits and restore without a store button',
    (tester) async {
      final c = FakeLicensing(FakeStore());
      final a = FakeAccount(c)
        ..email = null
        ..appAccountToken = null;
      await host(tester, c, a);
      expect(find.text('Unlock unlimited exports'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Manage subscription'), findsNothing);
      await tester.tap(find.text('Restore purchases'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No active purchase found.'), findsOneWidget);
    },
  );
  testWidgets('settings remains usable with narrow width and larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(440, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = FakeLicensing(FakeStore())..setAccess(paid());
    await host(tester, c, FakeAccount(c), full: true, scale: 1.5);
    expect(tester.takeException(), isNull);
  });
  testWidgets('settings visual preview capture', (tester) async {
    final directory = Platform.environment['SLIPREEL_UI_CAPTURE'];
    if (directory == null) return;
    for (final font in [
      ('Roboto', 'SLIPREEL_UI_FONT'),
      ('MaterialIcons', 'SLIPREEL_UI_ICONS'),
    ]) {
      final path = Platform.environment[font.$2];
      if (path == null) continue;
      final loader = FontLoader(font.$1)
        ..addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
        );
      await tester.runAsync(loader.load);
    }
    tester.view.physicalSize = const Size(1100, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = FakeLicensing(FakeStore())..setAccess(paid());
    await host(tester, c, FakeAccount(c), full: true);
    await expectLater(
      find.byKey(const Key('capture')),
      matchesGoldenFile('$directory/settings.png'),
    );
  });
}
