import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

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
}
