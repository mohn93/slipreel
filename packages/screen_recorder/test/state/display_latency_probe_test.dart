// packages/screen_recorder/test/state/display_latency_probe_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/display_latency_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('slipreel/video_sync');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getDisplayLatencyMicros') {
        expect((call.arguments as Map)['playerId'], 7);
        return 60000; // 60 ms
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('defaults to zero before polling', () {
    final probe = DisplayLatencyProbe(playerId: 7);
    expect(probe.latency.value, Duration.zero);
    probe.dispose();
  });

  test('pollOnce pulls a reading and smooths it into the notifier', () async {
    final probe = DisplayLatencyProbe(playerId: 7, alpha: 1.0);
    await probe.pollOnce();
    expect(probe.latency.value, const Duration(milliseconds: 60));
    probe.dispose();
  });

  test('a null playerId yields zero and never calls the channel', () async {
    final probe = DisplayLatencyProbe(playerId: null);
    await probe.pollOnce();
    expect(probe.latency.value, Duration.zero);
    probe.dispose();
  });
}
