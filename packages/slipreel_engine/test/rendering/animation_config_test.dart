import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';

void main() {
  group('ScreenAnimationConfig', () {
    test('preset config resolves badge curve and duration from the enum', () {
      const cfg = ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
      expect(cfg.badgeCurve, ScreenAnimationStyle.smooth.badgeCurve);
      expect(cfg.badgeDuration, ScreenAnimationStyle.smooth.badgeDuration);
      expect(cfg.rampCurve, ScreenAnimationStyle.smooth.rampCurve);
    });

    test('fromJson migrates unknown preset name to Smooth', () {
      // Unknown names no longer throw — they fall back to Smooth so
      // saved projects keep loading after a preset is removed.
      final cfg = ScreenAnimationConfig.fromJson({'preset': 'no-such-preset'});
      expect(cfg.preset, ScreenAnimationStyle.smooth);
    });

    test('retired #7 experimental preset names migrate to baked equivalents',
        () {
      expect(
        ScreenAnimationConfig.fromJson({'preset': 'studioSoft'}).preset,
        ScreenAnimationStyle.smooth,
      );
      expect(
        ScreenAnimationConfig.fromJson({'preset': 'studioSnappy'}).preset,
        ScreenAnimationStyle.focused,
      );
    });

    test('legacy custom JSON migrates to Smooth', () {
      // Old custom shape: curve + badgeDurationMicros, no 'preset' key.
      final cfg = ScreenAnimationConfig.fromJson({
        'curve': {'type': 'cubic', 'x1': 0.4, 'y1': 0.0, 'x2': 0.2, 'y2': 1.0},
        'badgeDurationMicros': 250000,
      });
      expect(cfg.preset, ScreenAnimationStyle.smooth);
      expect(cfg.toJson(), {'preset': 'smooth'});
    });

    test('preset round-trips', () {
      final cfg = ScreenAnimationConfig.fromJson({'preset': 'focused'});
      expect(cfg.preset, ScreenAnimationStyle.focused);
      expect(cfg.rampCurve, ScreenAnimationStyle.focused.rampCurve);
      expect(cfg.toJson(), {'preset': 'focused'});
    });
  });

  group('CursorAnimationConfig', () {
    test('preset config exposes window from re-tuning table', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      expect(cfg.window, CursorAnimationStyle.smooth.fir.window);
      expect(cfg.firCurve, CursorAnimationStyle.smooth.fir.curve);
    });

    test('window=0 preset is "None"', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.none);
      expect(cfg.window, Duration.zero);
    });

    test('fromJson migrates unknown preset name to Smooth', () {
      final cfg = CursorAnimationConfig.fromJson({'preset': 'no-such-preset'});
      expect(cfg.preset, CursorAnimationStyle.smooth);
    });

    test('retired #7 experimental preset names migrate to baked equivalents',
        () {
      expect(
        CursorAnimationConfig.fromJson({'preset': 'studioSoft'}).preset,
        CursorAnimationStyle.smooth,
      );
      expect(
        CursorAnimationConfig.fromJson({'preset': 'studioSnappy'}).preset,
        CursorAnimationStyle.medium,
      );
    });

    test('legacy custom-curve JSON migrates to Smooth', () {
      final cfg = CursorAnimationConfig.fromJson({
        'curve': {'type': 'cubic', 'x1': 0.4, 'y1': 0.0, 'x2': 0.2, 'y2': 1.0},
        'windowMicros': 450000,
      });
      expect(cfg.preset, CursorAnimationStyle.smooth);
      expect(cfg.toJson(), {'preset': 'smooth'});
    });

    test('legacy custom-spring JSON migrates to Smooth', () {
      final cfg = CursorAnimationConfig.fromJson({
        'spring': {'stiffness': 250.0, 'damping': 1.0},
      });
      expect(cfg.preset, CursorAnimationStyle.smooth);
      expect(cfg.motionSpring, CursorAnimationStyle.smooth.motionSpring);
    });

    test('preset value-equality holds', () {
      expect(
        const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
        const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
      );
      expect(
        const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
        isNot(const CursorAnimationConfig.preset(CursorAnimationStyle.medium)),
      );
    });
  });
}
