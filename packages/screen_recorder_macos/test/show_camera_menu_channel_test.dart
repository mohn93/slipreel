import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.slipreel.screen_recorder/recording');
  final platform = MethodChannelScreenRecorderMacos();

  test('showCameraMenu forwards current config and parses the chosen device',
      () async {
    Map<dynamic, dynamic>? sentArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'showCameraMenu') {
        sentArgs = call.arguments as Map?;
        return {'cancelled': false, 'config': {'deviceUid': 'cam2', 'deviceLabel': 'External'}};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final result = await platform.showCameraMenu(
        const CameraConfig(deviceUid: 'cam1', deviceLabel: 'FaceTime HD'));
    expect(sentArgs?['deviceUid'], 'cam1');
    expect(result.cancelled, isFalse);
    expect(result.config, const CameraConfig(deviceUid: 'cam2', deviceLabel: 'External'));
  });

  test('null channel result is a cancelled menu', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final result = await platform.showCameraMenu(null);
    expect(result.cancelled, isTrue);
    expect(result.config, isNull);
  });

  test('dontRecord response is not cancelled and has null config', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'showCameraMenu') {
        return {'cancelled': false, 'config': null};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final result = await platform.showCameraMenu(null);
    expect(result.cancelled, isFalse);
    expect(result.config, isNull);
  });
}
