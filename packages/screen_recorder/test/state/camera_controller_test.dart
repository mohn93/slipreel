// packages/screen_recorder/test/state/camera_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/camera_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('defaults to off (null) and updates on set', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(cameraControllerProvider), isNull);
    c.read(cameraControllerProvider.notifier)
        .set(const CameraConfig(deviceUid: 'u', deviceLabel: 'L'));
    expect(c.read(cameraControllerProvider),
        const CameraConfig(deviceUid: 'u', deviceLabel: 'L'));
  });
}
