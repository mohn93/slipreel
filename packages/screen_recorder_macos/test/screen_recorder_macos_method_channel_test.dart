import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelScreenRecorderMacos platform = MethodChannelScreenRecorderMacos();
  const MethodChannel channel = MethodChannel('com.slipreel.screen_recorder/recording');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        switch (methodCall.method) {
          case 'checkPermissions':
            return false;
          case 'getAvailableWindows':
            return [];
          case 'showMicrophoneMenu':
            return {
              'cancelled': false,
              'config': {
                'deviceUid': (methodCall.arguments as Map?)?['deviceUid'] ?? 'picked-uid',
                'deviceLabel': 'Picked Mic',
                'reduceNoise': false,
                'disableAgc': false,
              },
            };
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('checkPermissions returns false', () async {
    expect(await platform.checkPermissions(), false);
  });

  test('getAvailableWindows returns empty list', () async {
    expect(await platform.getAvailableWindows(), []);
  });

  test('showMicrophoneMenu sends current config and decodes the result', () async {
    final result = await platform.showMicrophoneMenu(
      const MicrophoneConfig(deviceUid: 'current-uid', deviceLabel: 'Current'));
    expect(result.cancelled, false);
    expect(result.config?.deviceLabel, 'Picked Mic');
  });

  test('showMicrophoneMenu(null) is allowed', () async {
    final result = await platform.showMicrophoneMenu(null);
    expect(result, isA<MicrophoneMenuResult>());
  });
}
