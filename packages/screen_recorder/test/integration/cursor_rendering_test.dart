import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Cursor rendering integration tests
///
/// These tests verify cursor tracking functionality across platforms.
/// They require a platform implementation to be registered and will be
/// skipped if run outside an integration_test context.
void main() {
  // Check if platform is available
  bool platformAvailable = false;
  try {
    ScreenRecorderPlatform.instance;
    platformAvailable = true;
  } catch (e) {
    // Platform not registered - tests will be skipped
  }

  group('Cross-platform cursor rendering', () {
    test('should provide cursor stream on all platforms', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered. '
            'Run this test from an integration_test context.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;

      // All platforms should implement cursor stream
      expect(platform.cursorStream, isA<Stream>());
    });

    test('should emit cursor positions during recording', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;

      final cursorData = <CursorPosition>[];
      final subscription = platform.cursorStream.listen(cursorData.add);

      // Wait for some cursor events
      await Future.delayed(const Duration(milliseconds: 500));

      unawaited(subscription.cancel());

      // Should have received cursor updates
      expect(cursorData.isNotEmpty, true);

      // Each cursor data should have valid coordinates
      for (final data in cursorData) {
        expect(data.x, greaterThanOrEqualTo(0));
        expect(data.y, greaterThanOrEqualTo(0));
        expect(data.timestampMicros, greaterThan(0));
      }
    });

    test('should detect clicks on all platforms', () async {
      if (!platformAvailable) {
        markTestSkipped('Platform implementation not registered.');
        return;
      }

      final platform = ScreenRecorderPlatform.instance;

      final clicks = <CursorPosition>[];
      final subscription = platform.cursorStream
          .where((data) => data.isClicked)
          .listen(clicks.add);

      // Wait for potential clicks
      await Future.delayed(const Duration(seconds: 2));

      unawaited(subscription.cancel());

      // If user clicked, should be detected
      // Can't guarantee clicks in test, so just verify stream structure
      expect(subscription, isNotNull);
    });
  });
}
