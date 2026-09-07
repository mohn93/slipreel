import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// The look half of an [EditorProjectState] — everything a template
/// carries. Excludes timeline content and transient UI (timelineScale,
/// pendingScaleAnchor). See the look-templates design doc.
class EditorLook {
  const EditorLook({
    required this.windowFrame,
    required this.cursorSize,
    required this.cursorStyle,
    required this.cursorClickEffect,
    required this.cursorShadow,
    required this.clickSpring,
    required this.cursorPostProcess,
    required this.hideCursorOverlay,
    required this.cursorDelay,
    required this.screenAnimationConfig,
    required this.cursorAnimationConfig,
    required this.motionBlur,
    required this.cursorMovementBlur,
    required this.screenMovementBlur,
    required this.screenZoomBlur,
    required this.outputAspect,
    required this.keystrokeOverlay,
    required this.cameraSettings,
    required this.captionStyle,
    required this.defaultZoomLook,
  });

  final WindowFrame windowFrame;
  final double cursorSize;
  final CursorStyle cursorStyle;
  final CursorClickEffect cursorClickEffect;
  final double cursorShadow;
  final ClickSpring clickSpring;
  final CursorPostProcess cursorPostProcess;
  final bool hideCursorOverlay;
  final Duration cursorDelay;
  final ScreenAnimationConfig screenAnimationConfig;
  final CursorAnimationConfig cursorAnimationConfig;
  final double motionBlur;
  final double cursorMovementBlur;
  final double screenMovementBlur;
  final double screenZoomBlur;
  final OutputAspect outputAspect;
  final KeystrokeOverlaySettings keystrokeOverlay;
  final CameraSettings cameraSettings;
  final CaptionStyle captionStyle;
  final ZoomLook defaultZoomLook;

  factory EditorLook.fromProject(EditorProjectState s) => EditorLook(
        windowFrame: s.windowFrame,
        cursorSize: s.cursorSize,
        cursorStyle: s.cursorStyle,
        cursorClickEffect: s.cursorClickEffect,
        cursorShadow: s.cursorShadow,
        clickSpring: s.clickSpring,
        cursorPostProcess: s.cursorPostProcess,
        hideCursorOverlay: s.hideCursorOverlay,
        cursorDelay: s.cursorDelay,
        screenAnimationConfig: s.screenAnimationConfig,
        cursorAnimationConfig: s.cursorAnimationConfig,
        motionBlur: s.motionBlur,
        cursorMovementBlur: s.cursorMovementBlur,
        screenMovementBlur: s.screenMovementBlur,
        screenZoomBlur: s.screenZoomBlur,
        outputAspect: s.outputAspect,
        keystrokeOverlay: s.keystrokeOverlay,
        cameraSettings: s.cameraSettings,
        captionStyle: s.captionStyle,
        defaultZoomLook: s.defaultZoomLook,
      );

  factory EditorLook.defaults() =>
      EditorLook.fromProject(EditorProjectState.defaults());

  EditorLook copyWith({
    WindowFrame? windowFrame,
    double? cursorSize,
    CursorStyle? cursorStyle,
    CursorClickEffect? cursorClickEffect,
    double? cursorShadow,
    ClickSpring? clickSpring,
    CursorPostProcess? cursorPostProcess,
    bool? hideCursorOverlay,
    Duration? cursorDelay,
    ScreenAnimationConfig? screenAnimationConfig,
    CursorAnimationConfig? cursorAnimationConfig,
    double? motionBlur,
    double? cursorMovementBlur,
    double? screenMovementBlur,
    double? screenZoomBlur,
    OutputAspect? outputAspect,
    KeystrokeOverlaySettings? keystrokeOverlay,
    CameraSettings? cameraSettings,
    CaptionStyle? captionStyle,
    ZoomLook? defaultZoomLook,
  }) =>
      EditorLook(
        windowFrame: windowFrame ?? this.windowFrame,
        cursorSize: cursorSize ?? this.cursorSize,
        cursorStyle: cursorStyle ?? this.cursorStyle,
        cursorClickEffect: cursorClickEffect ?? this.cursorClickEffect,
        cursorShadow: cursorShadow ?? this.cursorShadow,
        clickSpring: clickSpring ?? this.clickSpring,
        cursorPostProcess: cursorPostProcess ?? this.cursorPostProcess,
        hideCursorOverlay: hideCursorOverlay ?? this.hideCursorOverlay,
        cursorDelay: cursorDelay ?? this.cursorDelay,
        screenAnimationConfig:
            screenAnimationConfig ?? this.screenAnimationConfig,
        cursorAnimationConfig:
            cursorAnimationConfig ?? this.cursorAnimationConfig,
        motionBlur: motionBlur ?? this.motionBlur,
        cursorMovementBlur: cursorMovementBlur ?? this.cursorMovementBlur,
        screenMovementBlur: screenMovementBlur ?? this.screenMovementBlur,
        screenZoomBlur: screenZoomBlur ?? this.screenZoomBlur,
        outputAspect: outputAspect ?? this.outputAspect,
        keystrokeOverlay: keystrokeOverlay ?? this.keystrokeOverlay,
        cameraSettings: cameraSettings ?? this.cameraSettings,
        captionStyle: captionStyle ?? this.captionStyle,
        defaultZoomLook: defaultZoomLook ?? this.defaultZoomLook,
      );

  /// Returns this look with any device-frame fields cleared. Templates never
  /// carry a device bezel onto another recording (a device frame is intrinsic
  /// to a specific device capture, chosen at record time / auto-matched at
  /// load), so both the apply path and the fresh-recording seed strip it.
  EditorLook withoutDeviceFrame() =>
      copyWith(windowFrame: windowFrame.copyWith(clearDeviceFrame: true));

  Map<String, dynamic> toJson() => {
        'windowFrame': windowFrame.toJson(),
        'cursorSize': cursorSize,
        'cursorStyle': cursorStyle.name,
        'cursorClickEffect': cursorClickEffect.name,
        'cursorShadow': cursorShadow,
        'clickSpring': clickSpring.toJson(),
        'cursorPostProcess': cursorPostProcess.toJson(),
        'hideCursorOverlay': hideCursorOverlay,
        'cursorDelayMicros': cursorDelay.inMicroseconds,
        'screenAnimationConfig': screenAnimationConfig.toJson(),
        'cursorAnimationConfig': cursorAnimationConfig.toJson(),
        'motionBlur': motionBlur,
        'cursorMovementBlur': cursorMovementBlur,
        'screenMovementBlur': screenMovementBlur,
        'screenZoomBlur': screenZoomBlur,
        'outputAspect': outputAspect.name,
        'keystrokeOverlay': keystrokeOverlay.toJson(),
        'cameraSettings': cameraSettings.toJson(),
        'captionStyle': captionStyle.toJson(),
        'defaultZoomLook': defaultZoomLook.toJson(),
      };

  /// Decodes a look by layering the JSON onto a default project's JSON and
  /// reusing [EditorProjectState.fromJson]'s battle-tested per-field readers,
  /// then projecting back out. This guarantees identical decode semantics
  /// (clamps, enum fallbacks, section defaults) without duplicating them.
  factory EditorLook.fromJson(Map<String, dynamic> json) {
    final base = EditorProjectState.defaults().toJson();
    final merged = {...base, ...json};
    // fromJson requires a videoDuration for timeline seeding; the look
    // ignores timeline, so any non-zero duration is fine.
    final state = EditorProjectState.fromJson(
      merged,
      videoDuration: const Duration(seconds: 1),
    );
    return EditorLook.fromProject(state);
  }

  @override
  bool operator ==(Object other) =>
      other is EditorLook &&
      other.windowFrame == windowFrame &&
      other.cursorSize == cursorSize &&
      other.cursorStyle == cursorStyle &&
      other.cursorClickEffect == cursorClickEffect &&
      other.cursorShadow == cursorShadow &&
      other.clickSpring == clickSpring &&
      other.cursorPostProcess == cursorPostProcess &&
      other.hideCursorOverlay == hideCursorOverlay &&
      other.cursorDelay == cursorDelay &&
      other.screenAnimationConfig == screenAnimationConfig &&
      other.cursorAnimationConfig == cursorAnimationConfig &&
      other.motionBlur == motionBlur &&
      other.cursorMovementBlur == cursorMovementBlur &&
      other.screenMovementBlur == screenMovementBlur &&
      other.screenZoomBlur == screenZoomBlur &&
      other.outputAspect == outputAspect &&
      other.keystrokeOverlay == keystrokeOverlay &&
      other.cameraSettings == cameraSettings &&
      other.captionStyle == captionStyle &&
      other.defaultZoomLook == defaultZoomLook;

  @override
  int get hashCode => Object.hashAll([
        windowFrame,
        cursorSize,
        cursorStyle,
        cursorClickEffect,
        cursorShadow,
        clickSpring,
        cursorPostProcess,
        hideCursorOverlay,
        cursorDelay,
        screenAnimationConfig,
        cursorAnimationConfig,
        motionBlur,
        cursorMovementBlur,
        screenMovementBlur,
        screenZoomBlur,
        outputAspect,
        keystrokeOverlay,
        cameraSettings,
        captionStyle,
        defaultZoomLook,
      ]);
}
