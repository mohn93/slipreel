import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('fromMap parses window kind', () {
    final p = PickedSource.fromMap({'kind': 'window', 'id': '42'});
    expect(p.kind, RecordingSource.window);
    expect(p.id, '42');
  });

  test('fromMap parses screen kind', () {
    final p = PickedSource.fromMap({'kind': 'screen', 'id': '7'});
    expect(p.kind, RecordingSource.screen);
    expect(p.id, '7');
  });
}
