import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos.dart';

void main() {
  test('registerWith sets the platform instance', () {
    ScreenRecorderMacos.registerWith();
    expect(ScreenRecorderPlatform.instance, isNotNull);
  });
}
