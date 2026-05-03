import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';

void main() {
  group('BuiltInCurves', () {
    test('exposes the five CSS standard easings in a stable order', () {
      final ids = BuiltInCurves.all.map((e) => e.id).toList();
      expect(ids, [
        'linear',
        'ease',
        'ease-in',
        'ease-out',
        'ease-in-out',
      ]);
    });

    test('each built-in resolves to a CubicBezierCurve with known params', () {
      final ease = BuiltInCurves.byId('ease')!;
      expect(ease.curve, isA<CubicBezierCurve>());
      final cb = ease.curve as CubicBezierCurve;
      // CSS "ease" = cubic-bezier(0.25, 0.1, 0.25, 1.0)
      expect(cb.x1, closeTo(0.25, 1e-9));
      expect(cb.y1, closeTo(0.10, 1e-9));
      expect(cb.x2, closeTo(0.25, 1e-9));
      expect(cb.y2, closeTo(1.00, 1e-9));
    });

    test('byId returns null for unknown id', () {
      expect(BuiltInCurves.byId('nope'), isNull);
    });
  });
}
