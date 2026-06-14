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

/// Records the order in which the native pause/resume bodies actually run.
/// `pauseRecording` is deliberately slow so an un-serialized resume would
/// reach the native side first.
class _OrderedPlatform extends ScreenRecorderPlatform {
  _OrderedPlatform(this.order);
  final List<String> order;
  @override
  Future<void> pauseRecording() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    order.add('pause');
  }

  @override
  Future<void> resumeRecording() async {
    order.add('resume');
  }
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

  // m1: a rapid pause→resume toggle must reach the native side in order. The
  // old code flipped the Dart status synchronously and fired the platform call
  // without serializing, so a quick resume could overtake a slow pause.
  test('rapid pause then resume serializes native calls in order', () async {
    final order = <String>[];
    ScreenRecorderPlatform.instance = _OrderedPlatform(order);
    final c = RecordingController();
    c.state = c.state.copyWith(status: RecordingStatus.recording);

    final pause = c.pauseRecording();
    final resume = c.resumeRecording();
    await Future.wait([pause, resume]);

    expect(order, ['pause', 'resume']);
    expect(c.state.status, RecordingStatus.recording);
  });
}
