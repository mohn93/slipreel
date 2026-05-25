import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.slipreel.screen_recorder/recording');
  final log = <MethodCall>[];
  Object? response;

  setUp(() {
    response = null;
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return response;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pickSource(window) invokes pickSource with kind and parses result',
      () async {
    response = {'kind': 'window', 'id': '99'};
    final platform = MethodChannelScreenRecorderMacos();
    final picked = await platform.pickSource(RecordingSource.window);
    expect(log.single.method, 'pickSource');
    expect(log.single.arguments, {'kind': 'window'});
    expect(picked, isNotNull);
    expect(picked!.kind, RecordingSource.window);
    expect(picked.id, '99');
  });

  test('pickSource returns null when native returns null (cancel)', () async {
    response = null;
    final platform = MethodChannelScreenRecorderMacos();
    final picked = await platform.pickSource(RecordingSource.screen);
    expect(log.single.arguments, {'kind': 'screen'});
    expect(picked, isNull);
  });
}
