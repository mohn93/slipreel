// packages/screen_recorder/test/state/recording_device_test.dart
//
// Covers RecordingController.startDeviceRecording: it must resolve the output
// .mp4 under the save dir (same path-resolution the screen path uses), forward
// deviceId/captureDeviceAudio/captureMic to the platform, and transition the
// controller into an active device recording. The native side finalizes a
// device capture through the SAME stopLiveRecording path, so on stop the
// cursor/keystroke sidecars must be skipped (touch devices have no input
// tracking) while the metadata sidecar still writes.
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

class _FakePlatform extends ScreenRecorderPlatform
    with MockPlatformInterfaceMixin {
  String? deviceId;
  bool? deviceAudio;
  bool? mic;
  String? outputPath;

  @override
  Future<void> startDeviceRecording({
    required String deviceId,
    required bool captureDeviceAudio,
    required bool captureMic,
    required String outputPath,
  }) async {
    this.deviceId = deviceId;
    this.deviceAudio = captureDeviceAudio;
    this.mic = captureMic;
    this.outputPath = outputPath;
  }

  @override
  Stream<CursorPosition> get cursorStream => const Stream.empty();

  @override
  Stream<KeystrokeEvent> get keystrokeStream => const Stream.empty();

  @override
  Stream<String> get recordingErrorStream => const Stream.empty();
}

void main() {
  test('startDeviceRecording forwards args + path under save dir', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
    final platform = _FakePlatform();
    ScreenRecorderPlatform.instance = platform;

    final c = RecordingController();
    await c.startDeviceRecording(deviceId: 'uid-1', captureDeviceAudio: true);

    expect(platform.deviceId, 'uid-1');
    expect(platform.deviceAudio, true);
    expect(platform.mic, false);
    expect(platform.outputPath, endsWith('.mp4'));
    expect(platform.outputPath, startsWith('/tmp/test-docs/'));

    // Controller reflects an active device recording.
    expect(c.state.status, RecordingStatus.recording);
    expect(c.state.selectedSourceKind, RecordingSource.device);
    expect(c.state.isRecording, isTrue);

    c.dispose();
  });

  test('startDeviceRecording with a microphone sets captureMic true', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
    final platform = _FakePlatform();
    ScreenRecorderPlatform.instance = platform;

    final c = RecordingController();
    await c.startDeviceRecording(
      deviceId: 'uid-2',
      captureDeviceAudio: false,
      microphone: const MicrophoneConfig(deviceUid: 'mic-1', deviceLabel: 'Mic'),
    );

    expect(platform.mic, true);
    expect(platform.deviceAudio, false);

    c.dispose();
  });
}
