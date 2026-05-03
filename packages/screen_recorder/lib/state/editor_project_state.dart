import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';

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
    required this.windowFrame,
  });

  /// Sensible blank slate for a freshly-loaded recording with no saved
  /// project file. Matches the constants previously hard-coded in
  /// `_PlaybackScreenState`'s field initializers and the rounded
  /// frame template.
  factory EditorProjectState.defaults() => EditorProjectState(
        zoomRegions: const [],
        screenAnimationConfig: const ScreenAnimationConfig.preset(
            ScreenAnimationStyle.smooth),
        cursorAnimationConfig: const CursorAnimationConfig.preset(
            CursorAnimationStyle.smooth),
        cursorSize: 1.0,
        cursorStyle: CursorStyle.modernDark,
        cursorClickEffect: CursorClickEffect.ripple,
        hideCursorOverlay: false,
        motionBlur: 0,
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
  final WindowFrame windowFrame;

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
        'windowFrame': windowFrame.toJson(),
      };

  factory EditorProjectState.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is int && version > currentSchemaVersion) {
      throw FormatException(
          'EditorProjectState: schemaVersion $version is newer than '
          'this build supports ($currentSchemaVersion)');
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
      motionBlur:
          (json['motionBlur'] as num?)?.toDouble() ?? defaults.motionBlur,
      windowFrame:
          frame != null ? WindowFrame.fromJson(frame) : defaults.windowFrame,
    );
  }

  static T _decodeEnum<T extends Enum>(
      String? name, List<T> values, T fallback) {
    if (name == null) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw FormatException(
        'EditorProjectState: unknown enum value "$name" for ${values.first.runtimeType}');
  }
}
