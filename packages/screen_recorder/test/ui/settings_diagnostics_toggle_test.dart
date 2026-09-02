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

/// Minimal platform stub — same pattern as test/ui/screens/settings_screen_test.dart.
class _FakePlatform extends ScreenRecorderPlatform {}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    ScreenRecorderPlatform.instance = _FakePlatform();
  });

  testWidgets('diagnostics toggle flips shareDiagnostics', (tester) async {
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/tmp/x_rec.json'),
              initial: RecordingSettings.defaults)),
      globalPreferencesControllerProvider.overrideWith((ref) =>
          GlobalPreferencesController(
              store: GlobalPreferencesStore(path: '/tmp/x_glob.json'),
              initial: const GlobalPreferences(shareDiagnostics: true))),
      permissionsControllerProvider.overrideWith(
          (ref) => PermissionsController(ScreenRecorderPlatform.instance)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: [AppPalette.midnight],
          ),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump();

    final toggle = find.widgetWithText(
        SwitchListTile, 'Send crash & error reports');
    expect(toggle, findsOneWidget);

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pump();

    expect(
      container.read(globalPreferencesControllerProvider).shareDiagnostics,
      isFalse,
    );
  });
}
