import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('RegionSelection.fromMap', () {
    test('parses all fields', () {
      final r = RegionSelection.fromMap({
        'displayId': '69734662',
        'x': 100, 'y': 200,
        'width': 1280, 'height': 720,
      });
      expect(r.displayId, '69734662');
      expect(r.x, 100);
      expect(r.y, 200);
      expect(r.widthPx, 1280);
      expect(r.heightPx, 720);
    });

    test('round-trips through toMap', () {
      const original = RegionSelection(
          displayId: '1', x: 10, y: 20, widthPx: 100, heightPx: 200);
      final round = RegionSelection.fromMap(original.toMap());
      expect(round.displayId, '1');
      expect(round.x, 10);
      expect(round.y, 20);
      expect(round.widthPx, 100);
      expect(round.heightPx, 200);
    });

    test('defaults to zeros when fields missing', () {
      final r = RegionSelection.fromMap({});
      expect(r.displayId, '');
      expect(r.x, 0);
      expect(r.y, 0);
      expect(r.widthPx, 0);
      expect(r.heightPx, 0);
    });
  });

  group('ScreenRecorderMethods constants', () {
    test('selectRegion constant exists', () {
      expect(ScreenRecorderMethods.selectRegion, 'selectRegion');
    });
  });
}
