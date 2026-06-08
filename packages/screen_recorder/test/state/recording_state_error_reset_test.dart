// Regression test for M1: a failed native stop must not leave the
// VideoEncoder active. Otherwise the next Record press double-starts a
// second native capture on top of a still-running, unfinalized first one.
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => '/tmp/test-docs';
}

class _FlakyStopPlatform extends ScreenRecorderPlatform
    with MockPlatformInterfaceMixin {
  int startCount = 0;
  int stopAttempts = 0;
  bool failStop = true;

  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    startCount++;
  }

  @override
  Future<RecordingResult> stopLiveRecording() async {
    stopAttempts++;
    if (failStop) {
      throw StateError('native stopLiveRecording timed out');
    }
    return const RecordingResult(
      outputPath: '/tmp/test-docs/x.mp4',
      width: 1920,
      height: 1080,
      perfStats: NativePerfStats(
        droppedFrames: 0,
        cpuPctSamples: [],
        memBytesSamples: [],
      ),
    );
  }

  @override
  Stream<CursorPosition> get cursorStream => const Stream.empty();

  @override
  Stream<KeystrokeEvent> get keystrokeStream => const Stream.empty();

  @override
  Future<void> pauseRecording() async {}

  @override
  Future<void> resumeRecording() async {}
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
  });

  test('failed stop reaps the encoder; a retry starts exactly one new session',
      () async {
    final platform = _FlakyStopPlatform();
    ScreenRecorderPlatform.instance = platform;

    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');

    await c.startRecording();
    await Future<void>.delayed(Duration.zero);
    expect(platform.startCount, 1);
    expect(c.isEncoderActive, isTrue, reason: 'recording is live');

    // Native stop fails -> caught -> _handleError. The encoder must NOT be
    // left active, or the next start double-records.
    await c.stopRecording();
    await Future<void>.delayed(Duration.zero);
    expect(c.state.status, RecordingStatus.error);
    expect(c.isEncoderActive, isFalse,
        reason: 'the error path must reset the encoder (no leaked session)');
    expect(platform.stopAttempts, greaterThanOrEqualTo(2),
        reason: 'the error path should best-effort reap the native session');

    // The user retries. With the old session reaped, a fresh start is allowed
    // and starts exactly one new native session (not stacked on the first).
    platform.failStop = false;
    await c.startRecording();
    await Future<void>.delayed(Duration.zero);
    expect(platform.startCount, 2);
    expect(c.state.status, RecordingStatus.recording);

    c.dispose();
  });
}
