import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('ScreenRecorderChannels', () {
    test('all channels use the com.slipreel.screen_recorder prefix', () {
      const prefix = 'com.slipreel.screen_recorder/';
      expect(ScreenRecorderChannels.recording, '${prefix}recording');
      expect(ScreenRecorderChannels.frames, '${prefix}frames');
      expect(ScreenRecorderChannels.audio, '${prefix}audio');
      expect(ScreenRecorderChannels.cursor, '${prefix}cursor');
      expect(ScreenRecorderChannels.micLevel, '${prefix}micLevel');
    });
  });

  group('ScreenRecorderMethods', () {
    test('includes the accessibility + stock-cursor methods', () {
      expect(ScreenRecorderMethods.isAccessibilityTrusted, 'isAccessibilityTrusted');
      expect(ScreenRecorderMethods.requestAccessibilityPermission,
          'requestAccessibilityPermission');
      expect(ScreenRecorderMethods.getStockCursorImages, 'getStockCursorImages');
    });
  });
}
