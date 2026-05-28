// packages/screen_recorder_platform_interface/test/permission_status_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/permission_status.dart';

void main() {
  group('PermissionStatusCodec', () {
    test('round-trips all known values', () {
      for (final s in PermissionStatus.values) {
        expect(PermissionStatusCodec.fromWire(s.wire), s);
      }
    });

    test('unknown wire string falls back to notDetermined', () {
      expect(PermissionStatusCodec.fromWire('nonsense'),
          PermissionStatus.notDetermined);
    });

    test('null wire string falls back to notDetermined', () {
      expect(PermissionStatusCodec.fromWire(null),
          PermissionStatus.notDetermined);
    });

    test('PermissionKind has exactly three members', () {
      expect(PermissionKind.values, hasLength(3));
      expect(PermissionKind.values, containsAll(const [
        PermissionKind.screenRecording,
        PermissionKind.microphone,
        PermissionKind.accessibility,
      ]));
    });
  });
}
