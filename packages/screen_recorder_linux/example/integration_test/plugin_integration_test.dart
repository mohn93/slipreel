// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing


import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:screen_recorder_linux/screen_recorder_linux.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('getAvailableScreens test', (WidgetTester tester) async {
    final ScreenRecorderLinux plugin = ScreenRecorderLinux();
    final screens = await plugin.getAvailableScreens();

    // At least one screen should be available on Linux
    expect(screens.isNotEmpty, true);
    expect(screens.first.width, greaterThan(0));
    expect(screens.first.height, greaterThan(0));
  });

  testWidgets('checkPermissions test', (WidgetTester tester) async {
    final ScreenRecorderLinux plugin = ScreenRecorderLinux();
    final hasPermissions = await plugin.checkPermissions();

    // Should return a boolean
    expect(hasPermissions, isA<bool>());
  });
}
