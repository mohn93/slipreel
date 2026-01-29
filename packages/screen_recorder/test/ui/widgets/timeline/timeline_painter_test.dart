import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_painter.dart';

void main() {
  group('TimelinePainter', () {
    test('should calculate progress correctly', () {
      final painter = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
      );

      expect(painter.progress, 0.5);
    });

    test('should handle zero duration', () {
      final painter = TimelinePainter(
        duration: Duration.zero,
        position: Duration.zero,
      );

      expect(painter.progress, 0.0);
    });
  });
}
