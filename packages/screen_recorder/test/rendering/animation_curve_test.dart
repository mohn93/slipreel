import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';

void main() {
  group('CubicBezierCurve', () {
    test('toJson/fromJson roundtrips x1/y1/x2/y2', () {
      const c = CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4);
      final json = c.toJson();
      final back = AnimationCurve.fromJson(json);
      expect(back, isA<CubicBezierCurve>());
      final cb = back as CubicBezierCurve;
      expect(cb.x1, 0.42);
      expect(cb.y1, 0.0);
      expect(cb.x2, 0.58);
      expect(cb.y2, 1.4);
    });

    test('toFlutterCurve produces a Cubic with matching params', () {
      const c = CubicBezierCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0);
      final flutter = c.toFlutterCurve();
      expect(flutter, isA<Cubic>());
      // Sample at endpoints — every cubic bezier with locked (0,0)/(1,1)
      // must hit those corners regardless of control points.
      expect(flutter.transform(0.0), closeTo(0.0, 1e-6));
      expect(flutter.transform(1.0), closeTo(1.0, 1e-6));
    });

    test('equality is value-based', () {
      const a = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      const b = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      const c = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.5);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('PresetCurve', () {
    test('toJson/fromJson roundtrips presetId', () {
      const c = PresetCurve(presetId: 'screen.focused');
      final back = AnimationCurve.fromJson(c.toJson());
      expect(back, isA<PresetCurve>());
      expect((back as PresetCurve).presetId, 'screen.focused');
    });
  });
}
