import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';

void main() {
  group('OutputAspect', () {
    test('auto.ratio is null (resolved by caller against video size)', () {
      expect(OutputAspect.auto.ratio, isNull);
    });

    test('numeric ratios match width/height', () {
      expect(OutputAspect.wide16x9.ratio, closeTo(16 / 9, 1e-9));
      expect(OutputAspect.square1x1.ratio, closeTo(1.0, 1e-9));
      expect(OutputAspect.classic4x3.ratio, closeTo(4 / 3, 1e-9));
      expect(OutputAspect.vertical9x16.ratio, closeTo(9 / 16, 1e-9));
      expect(OutputAspect.tall3x4.ratio, closeTo(3 / 4, 1e-9));
      expect(OutputAspect.portrait4x5.ratio, closeTo(4 / 5, 1e-9));
    });

    test('labels are stable user-facing strings', () {
      expect(OutputAspect.auto.label, 'Auto');
      expect(OutputAspect.wide16x9.label, 'Wide 16:9');
      expect(OutputAspect.square1x1.label, 'Square 1:1');
      expect(OutputAspect.classic4x3.label, 'Classic 4:3');
      expect(OutputAspect.vertical9x16.label, 'Vertical 9:16');
      expect(OutputAspect.tall3x4.label, 'Tall 3:4');
      expect(OutputAspect.portrait4x5.label, 'Portrait 4:5');
    });

    test('name round-trip via values.byName', () {
      for (final v in OutputAspect.values) {
        expect(OutputAspect.values.byName(v.name), v);
      }
    });
  });
}
