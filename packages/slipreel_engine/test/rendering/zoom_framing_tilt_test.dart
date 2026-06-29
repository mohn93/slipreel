import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  group('normalizedFocalOffset (identity framing, 200x100 video)', () {
    final f = ZoomFraming.identity(const Size(200, 100));

    test('center is (0,0)', () {
      expect(f.normalizedFocalOffset(const Offset(100, 50)), const Offset(0, 0));
    });
    test('corners clamp to +/-1', () {
      expect(f.normalizedFocalOffset(const Offset(200, 100)), const Offset(1, 1));
      expect(f.normalizedFocalOffset(const Offset(0, 0)), const Offset(-1, -1));
    });
    test('beyond bounds is clamped', () {
      expect(f.normalizedFocalOffset(const Offset(400, -50)),
          const Offset(1, -1));
    });
  });

  group('perspectiveTilt', () {
    test('zero angles still set a height-scaled perspective entry', () {
      final f = ZoomFraming.identity(const Size(100, 100));
      final m = f.perspectiveTilt(0, 0);
      // entry(3,2) == -1/(height*kPerspective)
      expect(m.entry(3, 2), closeTo(-1 / (100 * kPerspective), 1e-12));
    });

    test('perspective strength scales with canvas height '
        '(resolution-independent)', () {
      final small = ZoomFraming.identity(const Size(100, 100));
      final big = ZoomFraming.identity(const Size(200, 200));
      expect(small.perspectiveTilt(0, 0).entry(3, 2) * 100,
          closeTo(big.perspectiveTilt(0, 0).entry(3, 2) * 200, 1e-9));
    });
  });
}
