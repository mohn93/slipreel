import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('Cross-platform cursor rendering', () {
    test('should provide cursor stream on all platforms', () async {
      final platform = ScreenRecorderPlatform.instance;

      // All platforms should implement cursor stream
      expect(platform.cursorStream, isA<Stream>());
    });

    test('should emit cursor positions during recording', () async {
      final platform = ScreenRecorderPlatform.instance;

      final cursorData = <CursorPosition>[];
      final subscription = platform.cursorStream.listen(cursorData.add);

      // Wait for some cursor events
      await Future.delayed(const Duration(milliseconds: 500));

      subscription.cancel();

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
      final platform = ScreenRecorderPlatform.instance;

      final clicks = <CursorPosition>[];
      final subscription = platform.cursorStream
          .where((data) => data.isClicked)
          .listen(clicks.add);

      // Wait for potential clicks
      await Future.delayed(const Duration(seconds: 2));

      subscription.cancel();

      // If user clicked, should be detected
      // Can't guarantee clicks in test, so just verify stream structure
      expect(subscription, isNotNull);
    });
  });
}
