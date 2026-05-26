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

class _CapturingPlatform extends ScreenRecorderPlatform
    with MockPlatformInterfaceMixin {
  RecordingSettings? capturedSettings;

  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    capturedSettings = settings;
  }

  @override
  Stream<CursorPosition> get cursorStream => const Stream.empty();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
  });

  test('startRecording forwards the microphone config into settings', () async {
    final platform = _CapturingPlatform();
    ScreenRecorderPlatform.instance = platform;
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');

    const mic = MicrophoneConfig(
        deviceUid: 'u', deviceLabel: 'L', reduceNoise: true);
    await c.startRecording(microphone: mic);
    await Future<void>.delayed(Duration.zero);

    expect(platform.capturedSettings?.microphone, mic);
    c.dispose();
  });

  test('startRecording with no mic leaves settings.microphone null', () async {
    final platform = _CapturingPlatform();
    ScreenRecorderPlatform.instance = platform;
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');

    await c.startRecording();
    await Future<void>.delayed(Duration.zero);

    expect(platform.capturedSettings?.microphone, isNull);
    c.dispose();
  });
}
