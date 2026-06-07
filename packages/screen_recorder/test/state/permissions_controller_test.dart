// packages/screen_recorder/test/state/permissions_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  PermissionStatus screenRec = PermissionStatus.notDetermined;
  PermissionStatus mic = PermissionStatus.notDetermined;
  PermissionStatus ax = PermissionStatus.notDetermined;
  PermissionStatus cam = PermissionStatus.notDetermined;

  @override
  Future<PermissionStatus> getScreenRecordingPermission() async => screenRec;
  @override
  Future<PermissionStatus> getMicrophonePermission() async => mic;
  @override
  Future<PermissionStatus> getAccessibilityPermission() async => ax;
  @override
  Future<PermissionStatus> getCameraPermission() async => cam;

  @override
  Future<PermissionStatus> requestMicrophonePermission() async {
    mic = PermissionStatus.granted;
    return mic;
  }

  @override
  Future<PermissionStatus> requestCameraPermission() async {
    cam = PermissionStatus.granted;
    return cam;
  }
}

void main() {
  test('refreshAll reads all kinds into snapshot', () async {
    final fake = _FakePlatform()
      ..screenRec = PermissionStatus.granted
      ..mic = PermissionStatus.denied
      ..ax = PermissionStatus.notDetermined
      ..cam = PermissionStatus.restricted;

    final controller = PermissionsController(fake);
    await controller.refreshAll();

    expect(controller.state.screenRec, PermissionStatus.granted);
    expect(controller.state.microphone, PermissionStatus.denied);
    expect(controller.state.accessibility, PermissionStatus.notDetermined);
    expect(controller.state.camera, PermissionStatus.restricted);
  });

  test('request(microphone) updates state', () async {
    final fake = _FakePlatform();
    final controller = PermissionsController(fake);
    await controller.refreshAll();
    expect(controller.state.microphone, PermissionStatus.notDetermined);

    final result = await controller.request(PermissionKind.microphone);

    expect(result, PermissionStatus.granted);
    expect(controller.state.microphone, PermissionStatus.granted);
  });

  test('request(camera) updates state', () async {
    final fake = _FakePlatform();
    final controller = PermissionsController(fake);
    await controller.refreshAll();
    expect(controller.state.camera, PermissionStatus.notDetermined);

    final result = await controller.request(PermissionKind.camera);

    expect(result, PermissionStatus.granted);
    expect(controller.state.camera, PermissionStatus.granted);
  });

  test('initial snapshot before refreshAll has all unsupported', () {
    final controller = PermissionsController(_FakePlatform());
    expect(controller.state.screenRec, PermissionStatus.unsupported);
    expect(controller.state.microphone, PermissionStatus.unsupported);
    expect(controller.state.accessibility, PermissionStatus.unsupported);
    expect(controller.state.camera, PermissionStatus.unsupported);
  });
}
