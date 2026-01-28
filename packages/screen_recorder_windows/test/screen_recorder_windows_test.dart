import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_windows/screen_recorder_windows.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenRecorderWindows', () {
    test('should register as platform instance', () {
      ScreenRecorderWindows.registerWith();
      expect(ScreenRecorderPlatform.instance, isA<ScreenRecorderWindows>());
    });

    test('should request permissions', () async {
      final plugin = ScreenRecorderWindows();
      final hasPermission = await plugin.requestPermissions();

      // Windows Graphics Capture requires user consent via picker
      expect(hasPermission, isA<bool>());
    });

    test('should get available windows', () async {
      final plugin = ScreenRecorderWindows();
      final windows = await plugin.getAvailableWindows();

      expect(windows, isA<List<WindowInfo>>());
      // At least the test process window should exist
      expect(windows.isNotEmpty, true);
    });

    test('should get available screens', () async {
      final plugin = ScreenRecorderWindows();
      final screens = await plugin.getAvailableScreens();

      expect(screens, isA<List<ScreenInfo>>());
      expect(screens.isNotEmpty, true);
    });
  });
}
