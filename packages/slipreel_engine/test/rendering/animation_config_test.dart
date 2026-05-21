import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';

void main() {
  group('ScreenAnimationConfig', () {
    test('preset config resolves badge curve and duration from the enum', () {
      const cfg = ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
      expect(cfg.badgeCurve, ScreenAnimationStyle.smooth.badgeCurve);
      expect(cfg.badgeDuration, ScreenAnimationStyle.smooth.badgeDuration);
      expect(cfg.rampCurve, ScreenAnimationStyle.smooth.rampCurve);
    });

    test('custom config resolves curve to the supplied bezier', () {
      const c = CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4);
      final cfg = ScreenAnimationConfig.custom(
        curve: c,
        badgeDuration: const Duration(milliseconds: 500),
      );
      expect(cfg.badgeCurve, isA<Cubic>());
      expect(cfg.rampCurve, isA<Cubic>());
      expect(cfg.badgeDuration, const Duration(milliseconds: 500));
    });

    test('custom without explicit duration falls back to Smooth preset', () {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      final cfg = ScreenAnimationConfig.custom(curve: c);
      expect(cfg.badgeDuration, ScreenAnimationStyle.smooth.badgeDuration);
    });

    test('fromJson throws on unknown preset name', () {
      expect(
        () => ScreenAnimationConfig.fromJson({'preset': 'no-such-preset'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('CursorAnimationConfig', () {
    test('preset config exposes window from re-tuning table', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      expect(cfg.window, CursorAnimationStyle.smooth.fir.window);
      expect(cfg.firCurve, CursorAnimationStyle.smooth.fir.curve);
    });

    test('custom config carries user window + curve', () {
      const c = CubicBezierCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0);
      final cfg = CursorAnimationConfig.custom(
        curve: c,
        window: const Duration(milliseconds: 500),
      );
      expect(cfg.window, const Duration(milliseconds: 500));
      expect(cfg.firCurve, isA<Cubic>());
    });

    test('window=0 preset is "None"', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.none);
      expect(cfg.window, Duration.zero);
    });

    test('fromJson throws on unknown preset name', () {
      expect(
        () => CursorAnimationConfig.fromJson({'preset': 'no-such-preset'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson custom throws on missing windowMicros', () {
      expect(
        () => CursorAnimationConfig.fromJson({
          'curve': const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4)
              .toJson(),
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
