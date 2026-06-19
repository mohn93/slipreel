import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
