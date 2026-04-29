import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/thumbnail_cache.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('ThumbnailCache', () {
    test('returns null for missing entries', () {
      final cache = ThumbnailCache();
      expect(cache.get(RecordingSource.window, '42'), isNull);
    });

    test('stores and retrieves bytes', () {
      final cache = ThumbnailCache();
      cache.put(RecordingSource.screen, '1', Uint8List.fromList([1, 2, 3]));
      expect(cache.get(RecordingSource.screen, '1'), [1, 2, 3]);
    });

    test('clear empties the cache', () {
      final cache = ThumbnailCache();
      cache.put(RecordingSource.window, 'a', Uint8List(0));
      cache.put(RecordingSource.screen, 'a', Uint8List(0));
      cache.clear();
      expect(cache.get(RecordingSource.window, 'a'), isNull);
      expect(cache.get(RecordingSource.screen, 'a'), isNull);
    });

    test('window and screen with same id are independent', () {
      final cache = ThumbnailCache();
      cache.put(RecordingSource.window, '1', Uint8List.fromList([10]));
      cache.put(RecordingSource.screen, '1', Uint8List.fromList([20]));
      expect(cache.get(RecordingSource.window, '1'), [10]);
      expect(cache.get(RecordingSource.screen, '1'), [20]);
    });
  });
}
