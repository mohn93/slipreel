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
          case 'startMicMonitor':
            return null;
          case 'stopMicMonitor':
            return null;
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

  test('startMicMonitor sends the microphone config', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return null;
    });
    await platform.startMicMonitor(
        const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic', reduceNoise: true));
    expect(calls.single.method, 'startMicMonitor');
    expect((calls.single.arguments as Map)['deviceUid'], 'u');
    expect((calls.single.arguments as Map)['reduceNoise'], true);
  });

  test('stopMicMonitor invokes the stop method', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return null;
    });
    await platform.stopMicMonitor();
    expect(calls.single.method, 'stopMicMonitor');
  });
}
