import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/rendering/spring_config.dart';
import 'package:screen_recorder/state/cursor_post_process.dart';

/// Per-recording editor settings that persist across app sessions.
///
/// Mirrors the mutable fields on `_PlaybackScreenState` that the
/// inspector lets the user edit, plus the frame chrome (wallpaper,
/// padding, corners, shadow, background blur) — the user expects all
/// of those to be locked to the clip they were dialed in for, not
/// applied globally. Saved to a `<videoPath>.editor.json` sidecar by
/// [EditorProjectStore].
class EditorProjectState {
  const EditorProjectState({
    required this.zoomRegions,
    required this.screenAnimationConfig,
    required this.cursorAnimationConfig,
    required this.cursorSize,
    required this.cursorStyle,
    required this.cursorClickEffect,
    required this.hideCursorOverlay,
    required this.motionBlur,
    this.cursorMovementBlur = 1.0,
    this.screenMovementBlur = 1.0,
    this.screenZoomBlur = 1.0,
    required this.cursorShadow,
    required this.clickSpring,
    required this.cursorDelay,
    required this.windowFrame,
    this.cursorPostProcess = CursorPostProcess.none,
  });

  /// Sensible blank slate for a freshly-loaded recording with no saved
  /// project file. Matches the constants previously hard-coded in
  /// `_PlaybackScreenState`'s field initializers and the rounded
  /// frame template.
  factory EditorProjectState.defaults() => EditorProjectState(
    zoomRegions: const [],
    screenAnimationConfig: const ScreenAnimationConfig.preset(
      ScreenAnimationStyle.smooth,
    ),
    cursorAnimationConfig: const CursorAnimationConfig.preset(
      CursorAnimationStyle.smooth,
    ),
    cursorSize: 2.0,
    cursorStyle: CursorStyle.modernDark,
    cursorClickEffect: CursorClickEffect.ripple,
    hideCursorOverlay: false,
    motionBlur: 0,
    cursorShadow: 0.4,
    clickSpring: ClickSpring.snappy,
    cursorDelay: const Duration(milliseconds: 50),
    windowFrame: WindowFrame.rounded(),
  );

  final List<ZoomRegion> zoomRegions;
  final ScreenAnimationConfig screenAnimationConfig;
  final CursorAnimationConfig cursorAnimationConfig;
  final double cursorSize;
  final CursorStyle cursorStyle;
  final CursorClickEffect cursorClickEffect;
  final bool hideCursorOverlay;
  final double motionBlur;
  final double cursorMovementBlur;
  final double screenMovementBlur;
  final double screenZoomBlur;

  /// Strength of the soft drop shadow rendered under the cursor glyph,
  /// 0..1. 0 disables; values closer to 1 push the shadow further
  /// down with more blur and opacity. Applies to every cursor type
  /// (arrow, dot, I-beam, pointing-hand, …) so the cursor reads as
  /// floating slightly above the recording.
  final double cursorShadow;

  /// Spring driving the click press-pulse (cursor shrinks on press,
  /// snaps back on release). Edited from the cursor tab's Springs
  /// section; defaults to [ClickSpring.snappy] for new projects.
  final ClickSpring clickSpring;

  /// How far back in time to sample the cursor track when rendering,
  /// so the sprite visually arrives at UI elements at the same moment
  /// they react in the recording (compensates for the app's UI
  /// redraw lag — most native macOS apps need ~30–80 ms; defaults to
  /// 50 ms as a universal starting point). Editable from the cursor
  /// tab's Debug section. Same value drives the export pipeline so
  /// the rendered MP4/GIF matches what the preview showed.
  final Duration cursorDelay;

  final WindowFrame windowFrame;

  /// Advanced cursor filters: end-of-clip freeze, shake removal,
  /// rapid-state-change debounce. Edited from the cursor tab's Advanced
  /// section. Defaults to [CursorPostProcess.none] — all filters off.
  final CursorPostProcess cursorPostProcess;

  /// Bumped whenever the on-disk JSON shape changes incompatibly. A
  /// loader can refuse to parse newer versions instead of guessing.
  static const int currentSchemaVersion = 2;

  Map<String, dynamic> toJson() => {
    'schemaVersion': currentSchemaVersion,
    'zoomRegions': zoomRegions.map((z) => z.toJson()).toList(),
    'screenAnimationConfig': screenAnimationConfig.toJson(),
    'cursorAnimationConfig': cursorAnimationConfig.toJson(),
    'cursorSize': cursorSize,
    'cursorStyle': cursorStyle.name,
    'cursorClickEffect': cursorClickEffect.name,
    'hideCursorOverlay': hideCursorOverlay,
    'motionBlur': motionBlur,
    'cursorMovementBlur': cursorMovementBlur,
    'screenMovementBlur': screenMovementBlur,
    'screenZoomBlur': screenZoomBlur,
    'cursorShadow': cursorShadow,
    'clickSpring': clickSpring.toJson(),
    'cursorDelayMicros': cursorDelay.inMicroseconds,
    'windowFrame': windowFrame.toJson(),
    'cursorPostProcess': cursorPostProcess.toJson(),
  };

  factory EditorProjectState.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is int && version > currentSchemaVersion) {
      throw FormatException(
        'EditorProjectState: schemaVersion $version is newer than '
        'this build supports ($currentSchemaVersion)',
      );
    }

    final zoomList = json['zoomRegions'];
    final zoomRegions = <ZoomRegion>[];
    if (zoomList is List) {
      for (final z in zoomList) {
        zoomRegions.add(ZoomRegion.fromJson(z as Map<String, dynamic>));
      }
    }

    final screen = json['screenAnimationConfig'] as Map<String, dynamic>?;
    final cursorAnim = json['cursorAnimationConfig'] as Map<String, dynamic>?;
    final frame = json['windowFrame'] as Map<String, dynamic>?;
    final defaults = EditorProjectState.defaults();

    return EditorProjectState(
      zoomRegions: zoomRegions,
      screenAnimationConfig: screen != null
          ? ScreenAnimationConfig.fromJson(screen)
          : defaults.screenAnimationConfig,
      cursorAnimationConfig: cursorAnim != null
          ? CursorAnimationConfig.fromJson(cursorAnim)
          : defaults.cursorAnimationConfig,
      cursorSize:
          (json['cursorSize'] as num?)?.toDouble() ?? defaults.cursorSize,
      cursorStyle: _decodeEnum<CursorStyle>(
        json['cursorStyle'] as String?,
        CursorStyle.values,
        defaults.cursorStyle,
      ),
      cursorClickEffect: _decodeEnum<CursorClickEffect>(
        json['cursorClickEffect'] as String?,
        CursorClickEffect.values,
        defaults.cursorClickEffect,
      ),
      hideCursorOverlay:
          (json['hideCursorOverlay'] as bool?) ?? defaults.hideCursorOverlay,
      // Motion-blur ranges were rescaled (master 0–2 → 0–0.5, channels
      // 0–2 → 0–1) after early-access. Clamp incoming JSON so projects
      // saved before the rescale don't push the sliders / smear past
      // their new caps and produce a "screen wipe" instead of motion
      // blur. The clamp is non-destructive — saving rewrites with the
      // clamped value, so subsequent loads are stable.
      motionBlur:
          ((json['motionBlur'] as num?)?.toDouble() ?? defaults.motionBlur)
              .clamp(0.0, 0.5),
      cursorMovementBlur:
          ((json['cursorMovementBlur'] as num?)?.toDouble() ??
                  defaults.cursorMovementBlur)
              .clamp(0.0, 1.0),
      screenMovementBlur:
          ((json['screenMovementBlur'] as num?)?.toDouble() ??
                  defaults.screenMovementBlur)
              .clamp(0.0, 1.0),
      screenZoomBlur:
          ((json['screenZoomBlur'] as num?)?.toDouble() ??
                  defaults.screenZoomBlur)
              .clamp(0.0, 1.0),
      cursorShadow:
          (json['cursorShadow'] as num?)?.toDouble() ?? defaults.cursorShadow,
      clickSpring: json['clickSpring'] is Map<String, dynamic>
          ? ClickSpring.fromJson(json['clickSpring'] as Map<String, dynamic>)
          : defaults.clickSpring,
      cursorDelay: json['cursorDelayMicros'] is int
          ? Duration(microseconds: json['cursorDelayMicros'] as int)
          : defaults.cursorDelay,
      windowFrame: frame != null
          ? WindowFrame.fromJson(frame)
          : defaults.windowFrame,
      cursorPostProcess: json['cursorPostProcess'] is Map<String, dynamic>
          ? CursorPostProcess.fromJson(
              json['cursorPostProcess'] as Map<String, dynamic>,
            )
          : CursorPostProcess.none,
    );
  }

  static T _decodeEnum<T extends Enum>(
    String? name,
    List<T> values,
    T fallback,
  ) {
    if (name == null) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw FormatException(
      'EditorProjectState: unknown enum value "$name" for ${values.first.runtimeType}',
    );
  }
}
