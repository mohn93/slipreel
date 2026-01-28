import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FrameSettingsProvider', () {
    test('should load default frame on init', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      expect(provider.currentFrame, isA<WindowFrame>());
      expect(provider.currentFrame.name, equals('None'));
    });

    test('should save and load custom frame', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      // Set a custom frame
      final customFrame = WindowFrame.rounded();
      await provider.setFrame(customFrame);

      // Create a new provider and load
      final provider2 = FrameSettingsProvider();
      await provider2.load();

      expect(provider2.currentFrame.name, equals('Rounded'));
      expect(provider2.currentFrame.padding, equals(const EdgeInsets.all(40)));
      expect(provider2.currentFrame.cornerRadius, equals(16.0));
    });

    test('should update frame properties individually', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      // Start with None frame
      expect(provider.currentFrame.name, equals('None'));

      // Update padding
      await provider.updatePadding(50.0);
      expect(provider.currentFrame.padding, equals(const EdgeInsets.all(50.0)));

      // Update corner radius
      await provider.updateCornerRadius(20.0);
      expect(provider.currentFrame.cornerRadius, equals(20.0));

      // Update shadow blur
      await provider.updateShadowBlur(30.0);
      expect(provider.currentFrame.shadowBlur, equals(30.0));

      // Update background color
      await provider.updateBackgroundColor(const Color(0xFFFF0000));
      expect(provider.currentFrame.backgroundColor, equals(const Color(0xFFFF0000)));
    });

    test('should select from templates', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      // Select Rounded template
      await provider.selectTemplate('Rounded');
      expect(provider.currentFrame.name, equals('Rounded'));
      expect(provider.currentFrame.padding, equals(const EdgeInsets.all(40)));

      // Select Modern template
      await provider.selectTemplate('Modern');
      expect(provider.currentFrame.name, equals('Modern'));
      expect(provider.currentFrame.padding, equals(const EdgeInsets.all(24)));

      // Select Minimal template
      await provider.selectTemplate('Minimal');
      expect(provider.currentFrame.name, equals('Minimal'));
      expect(provider.currentFrame.padding, equals(const EdgeInsets.all(16)));
    });
  });
}
