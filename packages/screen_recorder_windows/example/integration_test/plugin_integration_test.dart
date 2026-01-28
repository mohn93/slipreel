// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing


import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:screen_recorder_windows/screen_recorder_windows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('getAvailableScreens test', (WidgetTester tester) async {
    final ScreenRecorderWindows plugin = ScreenRecorderWindows();
    final screens = await plugin.getAvailableScreens();
    // Should have at least one screen
    expect(screens.isNotEmpty, true);
  });

  testWidgets('getAvailableWindows test', (WidgetTester tester) async {
    final ScreenRecorderWindows plugin = ScreenRecorderWindows();
    final windows = await plugin.getAvailableWindows();
    // Should return a list (might be empty on some systems)
    expect(windows, isA<List>());
  });
}
