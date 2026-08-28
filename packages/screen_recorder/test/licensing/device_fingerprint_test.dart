import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/device_fingerprint.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('slipreel/device');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('hashes the native hardware id with sha256', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'hardwareId');
      return 'ABCDEF12-3456-7890-ABCD-EF1234567890';
    });
    final fp = await DeviceFingerprint().compute();
    final expected = sha256
        .convert(utf8.encode('ABCDEF12-3456-7890-ABCD-EF1234567890'))
        .toString();
    expect(fp, expected);
    expect(fp.length, 64);
  });

  test('throws when native id is missing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(DeviceFingerprint().compute(),
        throwsA(isA<DeviceFingerprintUnavailable>()));
  });

  test('describe combines the device name with a macOS label', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'deviceName') return "Mohanned's MacBook Pro";
      return null;
    });
    final label = await DeviceFingerprint().describe();
    expect(label, contains("Mohanned's MacBook Pro"));
    expect(label, contains('macOS'));
  });

  test('describe falls back to the OS label when the name is unavailable',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final label = await DeviceFingerprint().describe();
    expect(label, contains('macOS'));
  });
}
