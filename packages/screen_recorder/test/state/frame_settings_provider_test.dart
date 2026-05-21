import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:slipreel_engine/models/window_frame.dart';

void main() {
  group('FrameSettingsProvider', () {
    test('starts on the rounded default', () {
      final provider = FrameSettingsProvider();
      expect(provider.currentFrame.name, 'Rounded');
    });

    test('setFrame replaces the held frame and notifies', () {
      final provider = FrameSettingsProvider();
      var notified = 0;
      provider.addListener(() => notified++);

      provider.setFrame(WindowFrame.minimal());
      expect(provider.currentFrame.name, 'Minimal');
      expect(notified, 1);
    });

    test('setFrame is a no-op when the frame is unchanged', () {
      // Important during init: when the playback screen restores a
      // frame from the sidecar that happens to match the current one,
      // we don't want a needless notify+save loop.
      final provider = FrameSettingsProvider();
      var notified = 0;
      provider.addListener(() => notified++);

      provider.setFrame(provider.currentFrame);
      expect(notified, 0);
    });

    test('individual mutators chain through setFrame', () {
      final provider = FrameSettingsProvider();
      provider.updatePadding(50);
      expect(provider.currentFrame.padding, const EdgeInsets.all(50));

      provider.updateCornerRadius(20);
      expect(provider.currentFrame.cornerRadius, 20);

      provider.updateShadowBlur(30);
      expect(provider.currentFrame.shadowBlur, 30);

      provider.updateBackgroundColor(const Color(0xFFFF0000));
      expect(provider.currentFrame.backgroundColor, const Color(0xFFFF0000));
    });

    test('selectTemplate switches to a known template', () {
      final provider = FrameSettingsProvider();
      provider.selectTemplate('Modern');
      expect(provider.currentFrame.name, 'Modern');
      expect(provider.currentFrame.padding, const EdgeInsets.all(24));

      provider.selectTemplate('Minimal');
      expect(provider.currentFrame.name, 'Minimal');
    });
  });
}
