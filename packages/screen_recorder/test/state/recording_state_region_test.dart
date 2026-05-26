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
  RegionSelection? capturedRegion;

  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    capturedSettings = settings;
    capturedRegion = region;
  }

  @override
  Stream<CursorPosition> get cursorStream => const Stream.empty();
}

void main() {
  test('initial selectedRegion is null', () {
    final c = RecordingController();
    expect(c.state.selectedRegion, isNull);
  });

  test('selectSource with region populates selectedRegion', () {
    final c = RecordingController();
    const region = RegionSelection(
        displayId: '1', x: 0, y: 0, widthPx: 800, heightPx: 600);
    c.selectSource(
        kind: RecordingSource.area, id: '1', region: region);
    expect(c.state.selectedSourceKind, RecordingSource.area);
    expect(c.state.selectedSourceId, '1');
    expect(c.state.selectedRegion, isNotNull);
    expect(c.state.selectedRegion!.widthPx, 800);
  });

  test('selectSource(null, null) clears region too', () {
    final c = RecordingController();
    c.selectSource(
      kind: RecordingSource.area,
      id: '1',
      region: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 100, heightPx: 100),
    );
    c.selectSource(kind: null, id: null);
    expect(c.state.selectedRegion, isNull);
  });

  test('startRecording forwards area kind and region to platform', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
    final platform = _CapturingPlatform();
    ScreenRecorderPlatform.instance = platform;

    final c = RecordingController();
    const region = RegionSelection(
        displayId: '1', x: 10, y: 20, widthPx: 1280, heightPx: 720);
    c.selectSource(kind: RecordingSource.area, id: '1', region: region);
    await c.startRecording();
    // Allow the awaited body to settle.
    await Future<void>.delayed(Duration.zero);

    expect(platform.capturedSettings, isNotNull);
    expect(platform.capturedSettings!.source, RecordingSource.area);
    expect(platform.capturedSettings!.sourceId, '1');
    expect(platform.capturedRegion, isNotNull);
    expect(platform.capturedRegion!.widthPx, 1280);
    expect(platform.capturedRegion!.heightPx, 720);

    // Stop the timer so the test exits cleanly.
    c.dispose();
  });
}
