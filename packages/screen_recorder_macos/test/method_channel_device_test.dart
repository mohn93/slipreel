import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = MethodChannelScreenRecorderMacos();
  const channel = MethodChannel('com.slipreel.screen_recorder/recording');
  final log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'listDevices') {
        return [
          {'id': 'uid-1', 'name': 'iPhone', 'kind': 'phone'},
          {'id': 'uid-2', 'name': 'iPad', 'kind': 'tablet'},
        ];
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    log.clear();
  });

  test('listDevices parses the native list into DeviceSources', () async {
    final devices = await platform.listDevices();
    expect(devices.map((d) => d.id), ['uid-1', 'uid-2']);
    expect(devices[1].kind, DeviceKind.tablet);
  });

  test('startDeviceRecording forwards args over the channel', () async {
    await platform.startDeviceRecording(
        deviceId: 'uid-1',
        captureDeviceAudio: true,
        captureMic: false,
        outputPath: '/tmp/out.mp4');
    final call = log.firstWhere((c) => c.method == 'startDeviceRecording');
    expect(call.arguments['deviceId'], 'uid-1');
    expect(call.arguments['captureDeviceAudio'], true);
    expect(call.arguments['captureMic'], false);
    expect(call.arguments['outputPath'], '/tmp/out.mp4');
  });
}
