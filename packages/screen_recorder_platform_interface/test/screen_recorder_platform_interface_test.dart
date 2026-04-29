import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _UnimplementedPlatform extends ScreenRecorderPlatform {}

void main() {
  group('ScreenRecorderPlatform abstract defaults', () {
    final p = _UnimplementedPlatform();

    test('listSources throws UnimplementedError', () {
      expect(() => p.listSources(), throwsA(isA<UnimplementedError>()));
    });

    test('captureThumbnail throws UnimplementedError', () {
      expect(
        () => p.captureThumbnail('1', RecordingSource.window),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('captureThumbnail throws ArgumentError for unsupported kind', () {
      expect(
        () => p.captureThumbnail('1', RecordingSource.area),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('selectRegion throws UnsupportedError', () {
      expect(() => p.selectRegion(), throwsA(isA<UnsupportedError>()));
    });
  });
}
