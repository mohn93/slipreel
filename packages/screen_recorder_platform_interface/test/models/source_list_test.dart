import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('SourceList.fromMap', () {
    test('parses windows and screens', () {
      final list = SourceList.fromMap({
        'windows': [
          {
            'id': '100',
            'title': 'Doc',
            'ownerName': 'Example',
            'x': 0, 'y': 0, 'width': 800, 'height': 600,
            'isOnScreen': true,
          },
        ],
        'screens': [
          {
            'id': '1',
            'name': 'Built-in',
            'width': 2560, 'height': 1600,
            'isPrimary': true,
          },
        ],
      });
      expect(list.windows, hasLength(1));
      expect(list.windows.first.title, 'Doc');
      expect(list.screens, hasLength(1));
      expect(list.screens.first.isPrimary, true);
    });

    test('defaults to empty when keys missing', () {
      final list = SourceList.fromMap({});
      expect(list.windows, isEmpty);
      expect(list.screens, isEmpty);
    });

    test('round-trips through toMap', () {
      final original = SourceList(
        windows: [
          const WindowInfo(
            id: '1', title: 't', ownerName: 'o',
            x: 0, y: 0, width: 100, height: 100,
          ),
        ],
        screens: [
          const ScreenInfo(id: '1', name: 'n', width: 100, height: 100),
        ],
      );
      final round = SourceList.fromMap(original.toMap());
      expect(round.windows.first.title, 't');
      expect(round.screens.first.name, 'n');
    });
  });

  group('ScreenRecorderMethods constants', () {
    test('listSources constant exists', () {
      expect(ScreenRecorderMethods.listSources, 'listSources');
    });

    test('captureThumbnail constant exists', () {
      expect(ScreenRecorderMethods.captureThumbnail, 'captureThumbnail');
    });
  });

}
