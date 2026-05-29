import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  int pauseCalls = 0;
  int resumeCalls = 0;
  @override
  Future<void> pauseRecording() async => pauseCalls++;
  @override
  Future<void> resumeRecording() async => resumeCalls++;
}

void main() {
  late _FakePlatform platform;
  setUp(() {
    platform = _FakePlatform();
    ScreenRecorderPlatform.instance = platform;
  });

  test('pauseRecording is a no-op when status != recording', () async {
    final c = RecordingController();
    expect(c.state.status, RecordingStatus.idle);
    await c.pauseRecording();
    expect(platform.pauseCalls, 0);
    expect(c.state.status, RecordingStatus.idle);
  });

  test('resumeRecording is a no-op when status != paused', () async {
    final c = RecordingController();
    await c.resumeRecording();
    expect(platform.resumeCalls, 0);
    expect(c.state.status, RecordingStatus.idle);
  });

  test('pauseRecording flips status to paused and calls native', () async {
    final c = RecordingController();
    c.state = c.state.copyWith(status: RecordingStatus.recording);
    await c.pauseRecording();
    expect(platform.pauseCalls, 1);
    expect(c.state.status, RecordingStatus.paused);
  });

  test('resumeRecording from paused flips status back to recording', () async {
    final c = RecordingController();
    c.state = c.state.copyWith(status: RecordingStatus.paused);
    await c.resumeRecording();
    expect(platform.resumeCalls, 1);
    expect(c.state.status, RecordingStatus.recording);
  });
}
