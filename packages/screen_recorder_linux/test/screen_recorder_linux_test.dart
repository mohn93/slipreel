import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_linux/screen_recorder_linux.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenRecorderLinux', () {
    test('should register as platform instance', () {
      ScreenRecorderLinux.registerWith();
      expect(ScreenRecorderPlatform.instance, isA<ScreenRecorderLinux>());
    });

    test('should request permissions', () async {
      final plugin = ScreenRecorderLinux();

      if (Platform.isLinux) {
        final hasPermission = await plugin.requestPermissions();
        // PipeWire requires portal permission
        expect(hasPermission, isA<bool>());
      } else {
        // On non-Linux platforms, expect MissingPluginException
        expect(
          () => plugin.requestPermissions(),
          throwsA(isA<MissingPluginException>()),
        );
      }
    });

    test('should check permissions', () async {
      final plugin = ScreenRecorderLinux();

      if (Platform.isLinux) {
        final hasPermission = await plugin.checkPermissions();
        expect(hasPermission, isA<bool>());
      } else {
        expect(
          () => plugin.checkPermissions(),
          throwsA(isA<MissingPluginException>()),
        );
      }
    });

    test('should get available windows', () async {
      final plugin = ScreenRecorderLinux();

      if (Platform.isLinux) {
        final windows = await plugin.getAvailableWindows();
        expect(windows, isA<List<WindowInfo>>());
      } else {
        expect(
          () => plugin.getAvailableWindows(),
          throwsA(isA<MissingPluginException>()),
        );
      }
    });

    test('should get available screens', () async {
      final plugin = ScreenRecorderLinux();

      if (Platform.isLinux) {
        final screens = await plugin.getAvailableScreens();
        expect(screens, isA<List<ScreenInfo>>());
        // At least one display should be available
        expect(screens.isNotEmpty, true);
      } else {
        expect(
          () => plugin.getAvailableScreens(),
          throwsA(isA<MissingPluginException>()),
        );
      }
    });

    test('should get audio devices', () async {
      final plugin = ScreenRecorderLinux();

      if (Platform.isLinux) {
        final devices = await plugin.getAudioDevices();
        expect(devices, isA<List<AudioDeviceInfo>>());
      } else {
        expect(
          () => plugin.getAudioDevices(),
          throwsA(isA<MissingPluginException>()),
        );
      }
    });
  });
}
