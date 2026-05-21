import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/effect_params.dart';

void main() {
  group('blurSigmaForIntensity', () {
    test('low intensity returns small sigma', () {
      expect(blurSigmaForIntensity(BlurIntensity.low), inInclusiveRange(2, 6));
    });
    test('high intensity returns large sigma', () {
      expect(blurSigmaForIntensity(BlurIntensity.high), greaterThan(20));
    });
    test('strictly increasing across intensities', () {
      final low = blurSigmaForIntensity(BlurIntensity.low);
      final medium = blurSigmaForIntensity(BlurIntensity.medium);
      final high = blurSigmaForIntensity(BlurIntensity.high);
      expect(low, lessThan(medium));
      expect(medium, lessThan(high));
    });
  });

  group('cornerRadiusPx', () {
    test('zero for none preset', () {
      expect(cornerRadiusPx(CornerRadiusPreset.none), 0);
    });
    test('positive for rounded preset', () {
      expect(cornerRadiusPx(CornerRadiusPreset.rounded), greaterThan(0));
    });
  });
}
