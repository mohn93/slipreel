import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_look.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  test('withLook carries every look field (coverage guard)', () {
    // Every field here differs from EditorProjectState.defaults(). If you add
    // a new look field to EditorProjectState, set it non-default here AND add
    // it to EditorLook; otherwise this test fails.
    final fancy = EditorProjectState.defaults().copyWith(
      windowFrame: WindowFrame.modern(),
      cursorSize: 4.2,
      cursorStyle: CursorStyle.dot,
      cursorClickEffect: CursorClickEffect.none,
      cursorShadow: 0.9,
      clickSpring: const ClickSpring(stiffness: 150, damping: 0.7),
      cursorPostProcess: const CursorPostProcess(endFreezeMs: 500),
      hideCursorOverlay: true,
      cursorDelay: const Duration(milliseconds: 120),
      screenAnimationConfig:
          const ScreenAnimationConfig.preset(ScreenAnimationStyle.focused),
      cursorAnimationConfig:
          const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
      motionBlur: 0.4,
      cursorMovementBlur: 0.7,
      screenMovementBlur: 0.6,
      screenZoomBlur: 0.5,
      outputAspect: OutputAspect.square1x1,
      keystrokeOverlay: const KeystrokeOverlaySettings(enabled: true),
      cameraSettings: const CameraSettings(
        enabled: false,
        shape: CameraShape.square,
      ),
      captionStyle: const CaptionStyle(enabled: true, fontScale: 1.6),
      defaultZoomLook: ZoomLook.cinematic,
    );

    final applied = EditorProjectState.defaults()
        .withLook(EditorLook.fromProject(fancy));

    expect(applied.windowFrame, fancy.windowFrame);
    expect(applied.cursorSize, fancy.cursorSize);
    expect(applied.cursorStyle, fancy.cursorStyle);
    expect(applied.cursorClickEffect, fancy.cursorClickEffect);
    expect(applied.cursorShadow, fancy.cursorShadow);
    expect(applied.clickSpring, fancy.clickSpring);
    expect(applied.cursorPostProcess, fancy.cursorPostProcess);
    expect(applied.hideCursorOverlay, fancy.hideCursorOverlay);
    expect(applied.cursorDelay, fancy.cursorDelay);
    expect(applied.screenAnimationConfig, fancy.screenAnimationConfig);
    expect(applied.cursorAnimationConfig, fancy.cursorAnimationConfig);
    expect(applied.motionBlur, fancy.motionBlur);
    expect(applied.cursorMovementBlur, fancy.cursorMovementBlur);
    expect(applied.screenMovementBlur, fancy.screenMovementBlur);
    expect(applied.screenZoomBlur, fancy.screenZoomBlur);
    expect(applied.outputAspect, fancy.outputAspect);
    expect(applied.keystrokeOverlay, fancy.keystrokeOverlay);
    expect(applied.cameraSettings, fancy.cameraSettings);
    expect(applied.captionStyle, fancy.captionStyle);
    expect(applied.defaultZoomLook, fancy.defaultZoomLook);

    // Every value must actually differ from defaults() for the guard to be
    // meaningful — otherwise a missing field in EditorLook would silently
    // pass because the default matches too.
    final defaults = EditorProjectState.defaults();
    expect(fancy.windowFrame, isNot(defaults.windowFrame));
    expect(fancy.cursorSize, isNot(defaults.cursorSize));
    expect(fancy.cursorStyle, isNot(defaults.cursorStyle));
    expect(fancy.cursorClickEffect, isNot(defaults.cursorClickEffect));
    expect(fancy.cursorShadow, isNot(defaults.cursorShadow));
    expect(fancy.clickSpring, isNot(defaults.clickSpring));
    expect(fancy.cursorPostProcess, isNot(defaults.cursorPostProcess));
    expect(fancy.hideCursorOverlay, isNot(defaults.hideCursorOverlay));
    expect(fancy.cursorDelay, isNot(defaults.cursorDelay));
    expect(
      fancy.screenAnimationConfig,
      isNot(defaults.screenAnimationConfig),
    );
    expect(
      fancy.cursorAnimationConfig,
      isNot(defaults.cursorAnimationConfig),
    );
    expect(fancy.motionBlur, isNot(defaults.motionBlur));
    expect(fancy.cursorMovementBlur, isNot(defaults.cursorMovementBlur));
    expect(fancy.screenMovementBlur, isNot(defaults.screenMovementBlur));
    expect(fancy.screenZoomBlur, isNot(defaults.screenZoomBlur));
    expect(fancy.outputAspect, isNot(defaults.outputAspect));
    expect(fancy.keystrokeOverlay, isNot(defaults.keystrokeOverlay));
    expect(fancy.cameraSettings, isNot(defaults.cameraSettings));
    expect(fancy.captionStyle, isNot(defaults.captionStyle));
    expect(fancy.defaultZoomLook, isNot(defaults.defaultZoomLook));
  });
}
