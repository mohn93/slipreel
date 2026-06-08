// Regression test for M7: a fatal mid-capture error reported by the native
// side (via recordingErrorStream) must move the controller out of "recording"
// and reap the encoder, instead of being silently swallowed.
import 'dart:async';

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

class _ErrorEmittingPlatform extends ScreenRecorderPlatform
    with MockPlatformInterfaceMixin {
  final errorController = StreamController<String>.broadcast();

  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {}

  @override
  Future<RecordingResult> stopLiveRecording() async => const RecordingResult(
        outputPath: '/tmp/test-docs/x.mp4',
        width: 1920,
        height: 1080,
        perfStats: NativePerfStats(
          droppedFrames: 0,
          cpuPctSamples: [],
          memBytesSamples: [],
        ),
      );

  @override
  Stream<CursorPosition> get cursorStream => const Stream.empty();

  @override
  Stream<KeystrokeEvent> get keystrokeStream => const Stream.empty();

  @override
  Stream<String> get recordingErrorStream => errorController.stream;
}

void main() {
  test('native recording error -> error state + encoder reaped', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
    final platform = _ErrorEmittingPlatform();
    ScreenRecorderPlatform.instance = platform;
    addTearDown(platform.errorController.close);

    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');
    await c.startRecording();
    await Future<void>.delayed(Duration.zero);
    expect(c.state.status, RecordingStatus.recording);
    expect(c.isEncoderActive, isTrue);

    // Native side reports a fatal mid-capture failure.
    platform.errorController.add('Screen capture stopped: display disconnected');
    await Future<void>.delayed(Duration.zero);

    expect(c.state.status, RecordingStatus.error);
    expect(c.state.error, contains('display disconnected'));
    expect(c.isEncoderActive, isFalse,
        reason: 'the error path must reap the native session');

    c.dispose();
  });
}
