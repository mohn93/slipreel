// Regression test for m2: reset() and dispose() must not abandon a live
// native capture. If the encoder is still active, tearing the controller down
// without reaping it leaks the native session (keeps recording with no owner).
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

class _LivePlatform extends ScreenRecorderPlatform
    with MockPlatformInterfaceMixin {
  int forceStops = 0;

  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {}

  @override
  Future<RecordingResult> stopLiveRecording() async {
    forceStops++;
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

  Future<RecordingController> startedController(_LivePlatform platform) async {
    ScreenRecorderPlatform.instance = platform;
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');
    await c.startRecording();
    await Future<void>.delayed(Duration.zero);
    expect(c.isEncoderActive, isTrue, reason: 'recording is live');
    return c;
  }

  test('reset() while recording reaps the encoder', () async {
    final platform = _LivePlatform();
    final c = await startedController(platform);

    c.reset();
    await Future<void>.delayed(Duration.zero);

    expect(c.isEncoderActive, isFalse,
        reason: 'reset must not abandon a live native session');
    expect(c.state.status, RecordingStatus.idle);
    c.dispose();
  });

  test('dispose() while recording reaps the encoder', () async {
    final platform = _LivePlatform();
    final c = await startedController(platform);

    c.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(platform.forceStops, greaterThanOrEqualTo(1),
        reason: 'dispose must best-effort stop the native session');
  });
}
