import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';

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
}
