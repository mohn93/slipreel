import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  group('EditorProjectState.copyWith', () {
    test('returns an identical instance when no overrides are passed', () {
      // Foundation for the Riverpod migration (P0-2): every inspector
      // edit will route through `controller.state = state.copyWith(...)`,
      // and a parameterless copyWith must round-trip every field so
      // identity-style equality checks downstream stay reliable.
      final original = EditorProjectState.defaults();
      final copy = original.copyWith();

      expect(copy.zoomRegions, equals(original.zoomRegions));
      expect(copy.screenAnimationConfig, equals(original.screenAnimationConfig));
      expect(copy.cursorAnimationConfig, equals(original.cursorAnimationConfig));
      expect(copy.cursorSize, equals(original.cursorSize));
      expect(copy.cursorStyle, equals(original.cursorStyle));
      expect(copy.cursorClickEffect, equals(original.cursorClickEffect));
      expect(copy.hideCursorOverlay, equals(original.hideCursorOverlay));
      expect(copy.motionBlur, equals(original.motionBlur));
      expect(copy.cursorMovementBlur, equals(original.cursorMovementBlur));
      expect(copy.screenMovementBlur, equals(original.screenMovementBlur));
      expect(copy.screenZoomBlur, equals(original.screenZoomBlur));
      expect(copy.cursorShadow, equals(original.cursorShadow));
      expect(copy.clickSpring, equals(original.clickSpring));
      expect(copy.cursorDelay, equals(original.cursorDelay));
      expect(copy.cursorPostProcess, equals(original.cursorPostProcess));
      expect(copy.windowFrame, equals(original.windowFrame));
    });

    test('overrides each named field independently without touching others',
        () {
      final original = EditorProjectState.defaults();

      final cursorSizeChange = original.copyWith(cursorSize: 5.0);
      expect(cursorSizeChange.cursorSize, 5.0);
      expect(cursorSizeChange.motionBlur, equals(original.motionBlur));
      expect(cursorSizeChange.cursorStyle, equals(original.cursorStyle));

      final motionBlurChange = original.copyWith(motionBlur: 0.75);
      expect(motionBlurChange.motionBlur, 0.75);
      expect(motionBlurChange.cursorSize, equals(original.cursorSize));

      final hideChange = original.copyWith(hideCursorOverlay: true);
      expect(hideChange.hideCursorOverlay, isTrue);
      expect(hideChange.cursorSize, equals(original.cursorSize));

      final delayChange = original.copyWith(
        cursorDelay: const Duration(milliseconds: 120),
      );
      expect(delayChange.cursorDelay, const Duration(milliseconds: 120));
      expect(delayChange.motionBlur, equals(original.motionBlur));
    });

    test('zoomRegions override replaces the list, not appends', () {
      // The controller will replace, never append in-place; copyWith
      // must mirror that. Verify by passing a freshly-constructed list
      // and confirming the new state's reference *is* the passed list,
      // not a copy of the original's.
      final original = EditorProjectState.defaults();
      final fresh = <ZoomRegion>[
        ZoomRegion(
          rect: const Rect.fromLTWH(0, 0, 10, 10),
          startTime: const Duration(milliseconds: 100),
          duration: const Duration(seconds: 1),
          zoomLevel: 2.0,
        ),
      ];
      final patched = original.copyWith(zoomRegions: fresh);
      expect(patched.zoomRegions, hasLength(1));
      expect(identical(patched.zoomRegions, fresh), isTrue);
      expect(original.zoomRegions, isEmpty); // original untouched
    });

    test(
      'overrides may downgrade derived enums to a different value '
      '(cursorStyle, cursorClickEffect, clickSpring, cursorPostProcess)',
      () {
        final original = EditorProjectState.defaults();
        const tighterSpring = ClickSpring(stiffness: 800, damping: 20);
        final swapped = original.copyWith(
          cursorStyle: CursorStyle.classic,
          cursorClickEffect: CursorClickEffect.none,
          clickSpring: tighterSpring,
          cursorPostProcess: const CursorPostProcess(
            endFreezeMs: 200,
            removeShakes: true,
            optimizeChanges: true,
          ),
        );
        expect(swapped.cursorStyle, CursorStyle.classic);
        expect(swapped.cursorClickEffect, CursorClickEffect.none);
        expect(swapped.clickSpring, tighterSpring);
        expect(swapped.cursorPostProcess.endFreezeMs, 200);

        // Original is untouched (immutable copyWith).
        expect(original.cursorStyle, CursorStyle.modernDark);
        expect(original.cursorClickEffect, CursorClickEffect.ripple);
        expect(original.clickSpring, ClickSpring.snappy);
        expect(original.cursorPostProcess, CursorPostProcess.none);
      },
    );

    test('animation configs swap atomically as a single unit', () {
      // CursorAnimationConfig has nested spring state — copyWith must
      // accept the new instance whole, not try to merge fields.
      final original = EditorProjectState.defaults();
      final next = original.copyWith(
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.rapid,
        ),
        screenAnimationConfig: const ScreenAnimationConfig.preset(
          ScreenAnimationStyle.focused,
        ),
      );
      expect(next.cursorAnimationConfig.preset, CursorAnimationStyle.rapid);
      expect(next.screenAnimationConfig.preset, ScreenAnimationStyle.focused);
    });
  });
}
