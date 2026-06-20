// packages/screen_recorder_platform_interface/test/device_source_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('DeviceSource round-trips through JSON', () {
    const s = DeviceSource(id: 'uid-1', name: 'Mohanned\'s iPhone', kind: DeviceKind.phone);
    final j = s.toJson();
    expect(j, {'id': 'uid-1', 'name': "Mohanned's iPhone", 'kind': 'phone'});
    final back = DeviceSource.fromJson(j);
    expect(back.id, 'uid-1');
    expect(back.name, "Mohanned's iPhone");
    expect(back.kind, DeviceKind.phone);
  });

  test('DeviceKind.fromName maps native labels; unknown → phone fallback', () {
    expect(DeviceSource.fromJson({'id': 'a', 'name': 'iPad', 'kind': 'tablet'}).kind, DeviceKind.tablet);
    expect(DeviceSource.fromJson({'id': 'a', 'name': 'X', 'kind': 'weird'}).kind, DeviceKind.phone);
  });

  test('RecordingSource has a device value', () {
    expect(RecordingSource.values.contains(RecordingSource.device), isTrue);
  });
}
