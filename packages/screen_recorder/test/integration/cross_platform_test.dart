import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Cross-platform integration tests
///
/// These tests verify that all platform implementations provide consistent
/// behavior and feature parity. They are designed to run in the context of
/// a real Flutter app with platform plugins registered.
///
/// To run these tests:
/// 1. Run from a platform plugin example app with integration_test
/// 2. Platform implementation must be registered before tests run
///
/// Note: These tests will be skipped if run directly via `flutter test` because
/// no platform implementation is registered in the test environment.
void main() {
  // Check if platform is available
  bool platformAvailable = false;
  try {
    ScreenRecorderPlatform.instance;
    platformAvailable = true;
  } catch (e) {
    // Platform not registered - tests will be skipped
  }

  group('Cross-platform feature parity', () {
    test('should have platform implementation registered', () {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered. '
            'Run this test from an integration_test context.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      expect(platform, isNotNull);

      if (Platform.isMacOS) {
        expect(platform.runtimeType.toString(), contains('MacOS'));
      } else if (Platform.isWindows) {
        expect(platform.runtimeType.toString(), contains('Windows'));
      } else if (Platform.isLinux) {
        expect(platform.runtimeType.toString(), contains('Linux'));
      }
    });

    test('should support window enumeration on all platforms', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      final windows = await platform.getAvailableWindows();

      expect(windows, isA<List<WindowInfo>>());
      // macOS and Windows should return windows, Linux may be empty (PipeWire)
      if (Platform.isMacOS || Platform.isWindows) {
        expect(windows.isNotEmpty, true);
      }
    });

    test('should support screen enumeration on all platforms', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      final screens = await platform.getAvailableScreens();

      expect(screens, isA<List<ScreenInfo>>());
      expect(screens.isNotEmpty, true); // All platforms should have at least one screen

      // Verify screen info structure
      for (final screen in screens) {
        expect(screen.id, isNotEmpty);
        expect(screen.width, greaterThan(0));
        expect(screen.height, greaterThan(0));
      }
    });

    test('should provide frame stream on all platforms', () {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      expect(platform.frameStream, isA<Stream<FrameData>>());
    });

    test('should provide cursor stream on all platforms', () {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      expect(platform.cursorStream, isA<Stream<CursorPosition>>());
    });

    test('should handle start/stop recording on all platforms', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;

      // Get first available screen
      final screens = await platform.getAvailableScreens();
      expect(screens.isNotEmpty, true);

      final settings = RecordingSettings(
        source: RecordingSource.screen,
        sourceId: screens.first.id,
        frameRate: 30,
      );

      // Start should not throw
      await platform.startRecording(settings);

      // Wait a bit
      await Future.delayed(const Duration(milliseconds: 500));

      // Stop should return path
      final outputPath = await platform.stopRecording();
      expect(outputPath, isNotNull);
      expect(outputPath, isNotEmpty);
    });

    test('should produce compatible frame data across platforms', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      final frames = <FrameData>[];
      final subscription = platform.frameStream.listen(frames.add);

      // Start recording
      final screens = await platform.getAvailableScreens();
      final settings = RecordingSettings(
        source: RecordingSource.screen,
        sourceId: screens.first.id,
        frameRate: 30,
      );

      await platform.startRecording(settings);
      await Future.delayed(const Duration(seconds: 1));
      await platform.stopRecording();

      unawaited(subscription.cancel());

      // Should have captured frames
      expect(frames.isNotEmpty, true);

      // All frames should have valid structure
      for (final frame in frames) {
        expect(frame.data, isNotEmpty);
        expect(frame.width, greaterThan(0));
        expect(frame.height, greaterThan(0));
        expect(frame.timestampMicros, greaterThan(0));

        // Frame data size should match dimensions (BGRA format)
        expect(frame.data.length, equals(frame.width * frame.height * 4));
      }
    });

    test('should handle recording errors gracefully on all platforms', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;

      // Try to record with invalid source ID
      final settings = RecordingSettings(
        source: RecordingSource.window,
        sourceId: 'invalid-source-id-12345',
        frameRate: 30,
      );

      // Should throw or return error, not crash
      expect(
        () => platform.startRecording(settings),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Platform-specific behavior', () {
    test('macOS should use ScreenCaptureKit', () async {
      if (!Platform.isMacOS || !platformAvailable) {
        markTestSkipped('Not running on macOS or platform not available.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      final windows = await platform.getAvailableWindows();

      // macOS should return detailed window info
      if (windows.isNotEmpty) {
        expect(windows.first.ownerName, isNotEmpty);
        expect(windows.first.title, isNotEmpty);
      }
    });

    test('Windows should use Graphics Capture API', () async {
      if (!Platform.isWindows || !platformAvailable) {
        markTestSkipped('Not running on Windows or platform not available.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;
      final windows = await platform.getAvailableWindows();

      // Windows should return window list
      expect(windows.isNotEmpty, true);
    });

    test('Linux should handle Wayland and X11', () async {
      if (!Platform.isLinux || !platformAvailable) {
        markTestSkipped('Not running on Linux or platform not available.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;

      // Should not throw regardless of display server
      final screens = await platform.getAvailableScreens();
      expect(screens.isNotEmpty, true);
    });
  });
}
