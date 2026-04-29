import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('initial state has no selection', () {
    final c = RecordingController();
    expect(c.state.selectedSourceId, isNull);
    expect(c.state.selectedSourceKind, isNull);
  });

  test('selectSource sets both kind and id', () {
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.window, id: '42');
    expect(c.state.selectedSourceId, '42');
    expect(c.state.selectedSourceKind, RecordingSource.window);
  });

  test('selectSource(null, null) clears the selection', () {
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');
    c.selectSource(kind: null, id: null);
    expect(c.state.selectedSourceId, isNull);
    expect(c.state.selectedSourceKind, isNull);
  });

  test('canStartRecording is true when idle', () {
    final c = RecordingController();
    expect(c.state.canStartRecording, true);
  });
}
