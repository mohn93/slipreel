// packages/slipreel_engine/test/rendering/animation_style_experimental_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';

void main() {
  test('experimental screen styles are excluded from the selectable set', () {
    final selectable =
        ScreenAnimationStyle.values.where((s) => !s.experimental).toList();
    expect(selectable, [ScreenAnimationStyle.focused, ScreenAnimationStyle.smooth]);
    expect(ScreenAnimationStyle.studioSoft.experimental, isTrue);
    expect(ScreenAnimationStyle.studioSnappy.experimental, isTrue);
  });

  test('experimental cursor styles are excluded from the selectable set', () {
    final selectable =
        CursorAnimationStyle.values.where((s) => !s.experimental).toList();
    expect(selectable, [
      CursorAnimationStyle.smooth,
      CursorAnimationStyle.medium,
      CursorAnimationStyle.rapid,
      CursorAnimationStyle.none,
    ]);
    expect(CursorAnimationStyle.studioSoft.experimental, isTrue);
    expect(CursorAnimationStyle.studioSnappy.experimental, isTrue);
  });

  test('every value resolves its curves/spring/label (switch totality)', () {
    for (final s in ScreenAnimationStyle.values) {
      expect(s.label, isNotEmpty);
      expect(s.rampCurve, isNotNull);
      expect(s.badgeCurve, isNotNull);
      expect(s.previewCurve, isNotNull);
    }
    for (final s in CursorAnimationStyle.values) {
      expect(s.label, isNotEmpty);
      expect(s.motionSpring, isNotNull);
      expect(s.previewCurve, isNotNull);
      expect(s.fir, isNotNull);
    }
  });
}
