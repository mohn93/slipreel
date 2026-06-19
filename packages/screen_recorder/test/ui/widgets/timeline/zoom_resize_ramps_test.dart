import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/zoom_lane.dart';

void main() {
  group('resolveResizeRamps — resizing does not rescale ramps (#4)', () {
    const enter = Duration(milliseconds: 500);
    const exit = Duration(milliseconds: 400);

    test('growing the region leaves enter/exit unchanged', () {
      final r = resolveResizeRamps(
        dragStartEnter: enter,
        dragStartExit: exit,
        newDuration: const Duration(seconds: 6), // grew from, say, 3s
      );
      expect(r.enter, enter);
      expect(r.exit, exit);
    });

    test('shrinking the region (still longer than ramps) leaves them unchanged',
        () {
      final r = resolveResizeRamps(
        dragStartEnter: enter,
        dragStartExit: exit,
        newDuration: const Duration(milliseconds: 1200), // > 900ms ramps
      );
      expect(r.enter, enter);
      expect(r.exit, exit);
    });

    test('translating the body (same duration) leaves them unchanged', () {
      final r = resolveResizeRamps(
        dragStartEnter: enter,
        dragStartExit: exit,
        newDuration: const Duration(seconds: 3),
      );
      expect(r.enter, enter);
      expect(r.exit, exit);
    });

    test('shrinking shorter than enter+exit compresses proportionally to fit',
        () {
      // 900ms of ramps into a 450ms region → halve both, sum == duration.
      final r = resolveResizeRamps(
        dragStartEnter: enter, // 500
        dragStartExit: exit, // 400
        newDuration: const Duration(milliseconds: 450),
      );
      expect(r.enter + r.exit, const Duration(milliseconds: 450));
      // factor = 450/900 = 0.5 → enter≈250, exit = remainder.
      expect(r.enter, const Duration(milliseconds: 250));
      expect(r.exit, const Duration(milliseconds: 200));
    });

    test('zero-duration ramps stay zero and never divide by zero', () {
      final r = resolveResizeRamps(
        dragStartEnter: Duration.zero,
        dragStartExit: Duration.zero,
        newDuration: const Duration(seconds: 2),
      );
      expect(r.enter, Duration.zero);
      expect(r.exit, Duration.zero);
    });
  });
}
