import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/trim_selection.dart';

void main() {
  group('TrimSelection', () {
    test('creates trim selection with valid start and end', () {
      const start = Duration(seconds: 2);
      const end = Duration(seconds: 8);
      const videoDuration = Duration(seconds: 10);

      final trim = TrimSelection(
        start: start,
        end: end,
        videoDuration: videoDuration,
      );

      expect(trim.start, equals(start));
      expect(trim.end, equals(end));
      expect(trim.duration, equals(const Duration(seconds: 6)));
    });

    test('auto-swaps start and end if start > end', () {
      const start = Duration(seconds: 8);
      const end = Duration(seconds: 2);
      const videoDuration = Duration(seconds: 10);

      final trim = TrimSelection(
        start: start,
        end: end,
        videoDuration: videoDuration,
      );

      expect(trim.start, equals(const Duration(seconds: 2)));
      expect(trim.end, equals(const Duration(seconds: 8)));
      expect(trim.duration, equals(const Duration(seconds: 6)));
    });

    test('constrains start and end to video duration', () {
      const start = Duration(seconds: -1);
      const end = Duration(seconds: 15);
      const videoDuration = Duration(seconds: 10);

      final trim = TrimSelection(
        start: start,
        end: end,
        videoDuration: videoDuration,
      );

      expect(trim.start, equals(Duration.zero));
      expect(trim.end, equals(videoDuration));
      expect(trim.duration, equals(videoDuration));
    });

    test('checks if position is within trim selection', () {
      const start = Duration(seconds: 2);
      const end = Duration(seconds: 8);
      const videoDuration = Duration(seconds: 10);

      final trim = TrimSelection(
        start: start,
        end: end,
        videoDuration: videoDuration,
      );

      expect(trim.contains(const Duration(seconds: 1)), isFalse);
      expect(trim.contains(const Duration(seconds: 2)), isTrue);
      expect(trim.contains(const Duration(seconds: 5)), isTrue);
      expect(trim.contains(const Duration(seconds: 8)), isTrue);
      expect(trim.contains(const Duration(seconds: 9)), isFalse);
    });
  });
}
