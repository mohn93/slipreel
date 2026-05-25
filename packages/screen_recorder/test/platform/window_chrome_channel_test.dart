import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/platform/window_chrome_channel.dart';
import 'package:screen_recorder/state/window_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('slipreel/window');
  final log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return null;
    });
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('setMode sends setMode with the mode name', () async {
    final chrome = MethodChannelWindowChrome();
    await chrome.setMode(WindowMode.panel);
    expect(log, hasLength(1));
    expect(log.single.method, 'setMode');
    expect(log.single.arguments, {'mode': 'panel'});
  });
}
