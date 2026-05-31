import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  group('EditorProjectController', () {
    test('starts with EditorProjectState.defaults()', () {
      final controller = EditorProjectController();
      expect(controller.state.cursorSize, equals(2.0));
      expect(controller.state.cursorStyle, CursorStyle.modernDark);
      expect(controller.state.motionBlur, 0);
      expect(controller.state.zoomRegions, isEmpty);
    });

    test('replace() swaps the entire state', () {
      // Used when loading a project from disk: the store hands the
      // controller a fully-built state, and the controller pushes it
      // straight through. No per-field copyWith dance.
      final controller = EditorProjectController();
      final loaded = EditorProjectState.defaults().copyWith(
        cursorSize: 3.5,
        motionBlur: 0.8,
        cursorPostProcess: const CursorPostProcess(endFreezeMs: 100),
      );
      controller.replace(loaded);
      expect(controller.state, same(loaded));
    });

    test('each updateX mutator changes only the targeted field', () {
      final controller = EditorProjectController();
      final initial = controller.state;

      controller.setCursorSize(4.0);
      expect(controller.state.cursorSize, 4.0);
      expect(controller.state.motionBlur, initial.motionBlur);

      controller.setMotionBlur(0.6);
      expect(controller.state.motionBlur, 0.6);
      expect(controller.state.cursorSize, 4.0);

      controller.setHideCursorOverlay(true);
      expect(controller.state.hideCursorOverlay, isTrue);
      expect(controller.state.motionBlur, 0.6);

      controller.setCursorStyle(CursorStyle.classic);
      expect(controller.state.cursorStyle, CursorStyle.classic);

      controller.setCursorClickEffect(CursorClickEffect.none);
      expect(controller.state.cursorClickEffect, CursorClickEffect.none);

      controller.setCursorShadow(0.75);
      expect(controller.state.cursorShadow, 0.75);

      controller.setCursorMovementBlur(0.5);
      controller.setScreenMovementBlur(0.4);
      controller.setScreenZoomBlur(0.3);
      expect(controller.state.cursorMovementBlur, 0.5);
      expect(controller.state.screenMovementBlur, 0.4);
      expect(controller.state.screenZoomBlur, 0.3);

      controller.setCursorDelay(const Duration(milliseconds: 90));
      expect(controller.state.cursorDelay, const Duration(milliseconds: 90));

      controller.setCursorPostProcess(
        const CursorPostProcess(endFreezeMs: 200),
      );
      expect(controller.state.cursorPostProcess.endFreezeMs, 200);

      controller.setClickSpring(const ClickSpring(stiffness: 900, damping: 25));
      expect(controller.state.clickSpring.stiffness, 900);

      controller.setScreenAnimationConfig(
        const ScreenAnimationConfig.preset(ScreenAnimationStyle.focused),
      );
      controller.setCursorAnimationConfig(
        const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
      );
      expect(
        controller.state.screenAnimationConfig.preset,
        ScreenAnimationStyle.focused,
      );
      expect(
        controller.state.cursorAnimationConfig.preset,
        CursorAnimationStyle.rapid,
      );
    });

    test('addZoom appends a region; updateZoomAt mutates by index; '
        'removeZoomAt removes by index', () {
      final controller = EditorProjectController();
      expect(controller.state.zoomRegions, isEmpty);

      final zoomA = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: const Duration(milliseconds: 100),
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      );
      final zoomB = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 1),
        zoomLevel: 3.0,
      );

      controller.addZoom(zoomA);
      controller.addZoom(zoomB);
      expect(controller.state.zoomRegions, hasLength(2));
      expect(controller.state.zoomRegions[0].zoomLevel, 2.0);
      expect(controller.state.zoomRegions[1].zoomLevel, 3.0);

      // updateZoomAt replaces the region at the given index.
      final zoomAEdited = ZoomRegion(
        rect: zoomA.rect,
        startTime: zoomA.startTime,
        duration: zoomA.duration,
        zoomLevel: 4.5,
      );
      controller.updateZoomAt(0, zoomAEdited);
      expect(controller.state.zoomRegions[0].zoomLevel, 4.5);
      expect(controller.state.zoomRegions[1].zoomLevel, 3.0);

      // removeZoomAt drops the indexed region.
      controller.removeZoomAt(0);
      expect(controller.state.zoomRegions, hasLength(1));
      expect(controller.state.zoomRegions[0].zoomLevel, 3.0);
    });

    group('setOutputAspect', () {
      test('publishes new state with the chosen aspect', () {
        final controller = EditorProjectController();
        expect(controller.current.outputAspect, OutputAspect.auto);

        controller.setOutputAspect(OutputAspect.vertical9x16);

        expect(controller.current.outputAspect, OutputAspect.vertical9x16);
      });
    });

    test('notifies listeners exactly once per mutator call', () {
      // Riverpod's StateNotifier publishes on assignment to `state`.
      // Each setter must do one assignment — not two — so the
      // observer count matches the mutation count.
      final controller = EditorProjectController();
      var notifications = 0;
      controller.addListener((_) => notifications++);
      // addListener fires once immediately with the current state.
      final baseline = notifications;

      controller.setCursorSize(3.0);
      controller.setCursorSize(4.0);
      controller.setMotionBlur(0.5);
      expect(notifications - baseline, equals(3));
    });
  });
}
