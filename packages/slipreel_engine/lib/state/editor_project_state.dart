import 'package:slipreel_engine/state/audio_mix.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

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
    required this.timeline,
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
    this.playbackSpeed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.audioMix = const AudioMix(),
  });

  /// Sensible blank slate for a freshly-loaded recording with no saved
  /// project file. Matches the constants previously hard-coded in
  /// `_PlaybackScreenState`'s field initializers and the rounded
  /// frame template.
  factory EditorProjectState.defaults() => EditorProjectState(
    timeline: Timeline.defaults(),
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

  /// Container for zoom tracks (and, in follow-ups, caption + audio
  /// tracks and multi-clip splits). Replaces the flat `zoomRegions`
  /// list as of schema v3.
  final Timeline timeline;

  /// Convenience read accessor for code that hasn't been updated to
  /// pick a specific zoom track. Returns the active (first) track's
  /// regions — matches today's single-track editor UI. New code
  /// should reach through `state.timeline.zoomTracks[i].regions`
  /// directly once multi-track lands.
  List<ZoomRegion> get zoomRegions => timeline.activeZoomRegions;

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

  /// Playback speed multiplier for the clip (1.0 = native). Edited
  /// from the Clip context inspector. The MP4 export pipeline applies
  /// this (setpts on video, atempo on audio); GIF speed is being wired
  /// separately. Round-tripped through persistence.
  final double playbackSpeed;

  /// Fade-in duration applied at the start of the clip. The MP4 export
  /// pipeline applies this (fade on video, afade on audio); GIF fades
  /// are being wired separately. See [playbackSpeed].
  final Duration fadeIn;

  /// Fade-out duration applied at the end of the clip. See [fadeIn].
  final Duration fadeOut;

  /// Per-track recording-audio volume/mute, applied as an ffmpeg downmix at
  /// export. Preview is unaffected (export-only mixing).
  final AudioMix audioMix;

  /// Bumped whenever the on-disk JSON shape changes incompatibly. A
  /// loader can refuse to parse newer versions instead of guessing.
  static const int currentSchemaVersion = 4;

  /// Returns a new instance with the named fields replaced.
  ///
  /// Used by `EditorProjectController` (the Riverpod notifier) to
  /// produce the next state on every inspector edit.
  EditorProjectState copyWith({
    Timeline? timeline,
    List<ZoomRegion>? zoomRegions,
    ScreenAnimationConfig? screenAnimationConfig,
    CursorAnimationConfig? cursorAnimationConfig,
    double? cursorSize,
    CursorStyle? cursorStyle,
    CursorClickEffect? cursorClickEffect,
    bool? hideCursorOverlay,
    double? motionBlur,
    double? cursorMovementBlur,
    double? screenMovementBlur,
    double? screenZoomBlur,
    double? cursorShadow,
    ClickSpring? clickSpring,
    Duration? cursorDelay,
    CursorPostProcess? cursorPostProcess,
    WindowFrame? windowFrame,
    double? playbackSpeed,
    Duration? fadeIn,
    Duration? fadeOut,
    AudioMix? audioMix,
  }) {
    // `zoomRegions:` is a convenience override that writes through to
    // the active (first) zoom track on the timeline — matches today's
    // single-track inspector. Passing both `timeline:` and
    // `zoomRegions:` is ambiguous, so prefer the explicit timeline.
    final Timeline nextTimeline;
    if (timeline != null) {
      nextTimeline = timeline;
    } else if (zoomRegions != null) {
      final tracks = this.timeline.zoomTracks;
      if (tracks.isEmpty) {
        nextTimeline = Timeline(zoomTracks: [ZoomTrack(regions: zoomRegions)]);
      } else {
        final updated = List<ZoomTrack>.from(tracks);
        updated[0] = tracks[0].copyWith(regions: zoomRegions);
        nextTimeline = Timeline(zoomTracks: updated);
      }
    } else {
      nextTimeline = this.timeline;
    }

    return EditorProjectState(
      timeline: nextTimeline,
      screenAnimationConfig:
          screenAnimationConfig ?? this.screenAnimationConfig,
      cursorAnimationConfig:
          cursorAnimationConfig ?? this.cursorAnimationConfig,
      cursorSize: cursorSize ?? this.cursorSize,
      cursorStyle: cursorStyle ?? this.cursorStyle,
      cursorClickEffect: cursorClickEffect ?? this.cursorClickEffect,
      hideCursorOverlay: hideCursorOverlay ?? this.hideCursorOverlay,
      motionBlur: motionBlur ?? this.motionBlur,
      cursorMovementBlur: cursorMovementBlur ?? this.cursorMovementBlur,
      screenMovementBlur: screenMovementBlur ?? this.screenMovementBlur,
      screenZoomBlur: screenZoomBlur ?? this.screenZoomBlur,
      cursorShadow: cursorShadow ?? this.cursorShadow,
      clickSpring: clickSpring ?? this.clickSpring,
      cursorDelay: cursorDelay ?? this.cursorDelay,
      cursorPostProcess: cursorPostProcess ?? this.cursorPostProcess,
      windowFrame: windowFrame ?? this.windowFrame,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
      audioMix: audioMix ?? this.audioMix,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': currentSchemaVersion,
    'timeline': timeline.toJson(),
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
    'playbackSpeed': playbackSpeed,
    'fadeInMicros': fadeIn.inMicroseconds,
    'fadeOutMicros': fadeOut.inMicroseconds,
    'audioMix': audioMix.toJson(),
  };

  factory EditorProjectState.fromJson(Map<String, dynamic> rawJson) {
    final version = rawJson['schemaVersion'];
    if (version is int && version > currentSchemaVersion) {
      throw FormatException(
        'EditorProjectState: schemaVersion $version is newer than '
        'this build supports ($currentSchemaVersion)',
      );
    }

    // Walk old sidecars forward through the migration chain so the
    // field readers below only ever see the current shape. A v2 JSON
    // (flat zoomRegions list) is reshaped into a v3 JSON (timeline
    // container) by the v2→v3 step before we look up `timeline`.
    final json = migrateEditorProjectJson(rawJson);

    final timelineJson = json['timeline'];
    final timeline = timelineJson is Map<String, dynamic>
        ? Timeline.fromJson(timelineJson)
        : Timeline.defaults();

    final screen = json['screenAnimationConfig'] as Map<String, dynamic>?;
    final cursorAnim = json['cursorAnimationConfig'] as Map<String, dynamic>?;
    final frame = json['windowFrame'] as Map<String, dynamic>?;
    final defaults = EditorProjectState.defaults();

    return EditorProjectState(
      timeline: timeline,
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
      playbackSpeed:
          (json['playbackSpeed'] as num?)?.toDouble() ?? defaults.playbackSpeed,
      fadeIn: json['fadeInMicros'] is num
          ? Duration(microseconds: (json['fadeInMicros'] as num).round())
          : defaults.fadeIn,
      fadeOut: json['fadeOutMicros'] is num
          ? Duration(microseconds: (json['fadeOutMicros'] as num).round())
          : defaults.fadeOut,
      audioMix: json['audioMix'] is Map<String, dynamic>
          ? AudioMix.fromJson(json['audioMix'] as Map<String, dynamic>)
          : defaults.audioMix,
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

// ---------------------------------------------------------------------------
// Schema migration switchboard
//
// Each entry in [_schemaMigrations] maps the JSON shape from vN to vN+1.
// [migrateEditorProjectJson] applies them in order starting at the
// inferred input version, returning a JSON the current build can read
// directly. Index 0 is v0→v1, index 1 is v1→v2, etc.
//
// **Pattern for adding a new schema version:**
//
// 1. Bump [EditorProjectState.currentSchemaVersion] from N to N+1.
// 2. Add a `Map<String, dynamic> _vNtoNPlus1(Map<String, dynamic>)`
//    function that transforms the old shape into the new shape
//    (rename fields, restructure objects, fill in derived defaults).
// 3. Append it to [_schemaMigrations] in order.
// 4. Update [toJson] for the new shape if the changed fields are
//    serialised by name. Add a regression test alongside.
//
// Recordings written by builds older than this one will then load
// through the chain instead of silently mis-parsing.
// ---------------------------------------------------------------------------

/// Ordered list of vN → vN+1 migration functions. Index `i` migrates
/// from schemaVersion `i` to `i + 1`.
final List<Map<String, dynamic> Function(Map<String, dynamic>)>
    _schemaMigrations = [
  // v0 → v1: no-op. v0 is hypothetical (pre-public builds); v1
  // recordings exist in the wild, so the chain starts at v1.
  (json) => json,
  // v1 → v2: insert the schemaVersion field. v1 sidecars predate
  // the version marker and assume the current build can identify
  // them by its absence. Any additional v1→v2 shape changes go here
  // too — today there are none, but the comment block above explains
  // how to grow this.
  (json) => {...json, 'schemaVersion': 2},
  // v2 → v3: move the flat `zoomRegions` list onto a single zoom
  // track inside a `timeline` container — scaffolding for captions,
  // audio, and multi-clip support that all land on the same root
  // object. The transform is lossless for v2 projects: the active
  // (only) zoom track wraps the previous list.
  (json) {
    final next = {...json, 'schemaVersion': 3};
    final regions = next.remove('zoomRegions');
    next['timeline'] = {
      'zoomTracks': [
        {'regions': regions is List ? regions : const <dynamic>[]},
      ],
    };
    return next;
  },
  // v3 → v4: add the per-track `audioMix` block. Additive — fromJson fills the
  // unity default when the key is absent, so the migration only bumps the
  // version marker so the chain reaches v4.
  (json) => {...json, 'schemaVersion': 4},
];

/// Walks [json] forward through [_schemaMigrations] until its
/// `schemaVersion` matches [EditorProjectState.currentSchemaVersion].
/// Exposed (not private) so the migration pipeline can be unit-tested
/// in isolation from `fromJson`.
///
/// A JSON without a `schemaVersion` field is treated as v1 — the
/// pre-versioned shape — since v0 was hypothetical and never shipped.
Map<String, dynamic> migrateEditorProjectJson(Map<String, dynamic> json) {
  final rawVersion = json['schemaVersion'];
  var version = (rawVersion is int && rawVersion >= 0) ? rawVersion : 1;
  var current = json;
  while (version < EditorProjectState.currentSchemaVersion) {
    if (version >= _schemaMigrations.length) {
      throw StateError(
        'No migration step from EditorProjectState v$version — '
        '_schemaMigrations is missing an entry. Add a v$version→v${version + 1} '
        'step or update currentSchemaVersion.',
      );
    }
    current = _schemaMigrations[version](current);
    version++;
  }
  return current;
}
