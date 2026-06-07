import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.slipreel.screen_recorder/recording');
  final platform = MethodChannelScreenRecorderMacos();
  final calls = <String>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getCameraPermission') return 'granted';
      if (call.method == 'requestCameraPermission') return 'denied';
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('getCameraPermission maps the wire string to a status', () async {
    final status = await platform.getCameraPermission();
    expect(calls, contains('getCameraPermission'));
    expect(status, PermissionStatus.granted);
  });

  test('requestCameraPermission maps the wire string to a status', () async {
    final status = await platform.requestCameraPermission();
    expect(calls, contains('requestCameraPermission'));
    expect(status, PermissionStatus.denied);
  });
}
