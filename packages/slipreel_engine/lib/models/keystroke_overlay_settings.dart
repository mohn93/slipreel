import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Where keystroke badges are anchored on the canvas.
enum KeystrokePosition {
  centerBottom,
  bottomLeft,
  bottomRight;

  String get label => switch (this) {
    centerBottom => 'Center',
    bottomLeft => 'Left',
    bottomRight => 'Right',
  };
}

/// Per-project configuration for the keystroke overlay that appears on
/// the canvas during playback and export, plus the shortcuts timeline lane
/// shown in the editor.
class KeystrokeOverlaySettings {
  const KeystrokeOverlaySettings({
    this.enabled = false,
    this.position = KeystrokePosition.centerBottom,
    this.labelScale = 1.0,
    this.fadeSecs = 2.0,
    this.showSingleKeyShortcuts = false,
    this.showTimeline = true,
    this.singleBox = false,
    this.disabledKeys = const <int>{},
  });

  /// Smallest / largest / default multiplier for the on-canvas keycaps.
  static const double minLabelScale = 0.6;
  static const double maxLabelScale = 2.0;
  static const double defaultLabelScale = 1.0;

  /// Whether to render the overlay at all. Toggled in the Shortcuts tab.
  final bool enabled;

  /// Canvas anchor for the badge stack. No longer exposed in the UI — kept
  /// so existing projects keep their alignment and a picker can return later.
  final KeystrokePosition position;

  /// Multiplier on the keycap size drawn over the video (driven by the
  /// "Shortcut labels size" slider). 1.0 is the default size.
  final double labelScale;

  /// Seconds each keystroke badge stays visible (including fade-out).
  final double fadeSecs;

  /// When true, single navigation/action keys (Space, ↩, arrows, F-keys…)
  /// are shown in addition to multi-key shortcuts. Plain typing is never
  /// shown either way.
  final bool showSingleKeyShortcuts;

  /// Whether the shortcuts timeline lane is shown in the editor. Only has
  /// an effect while [enabled] is true.
  final bool showTimeline;

  /// When true the overlay shows only the single most recent shortcut; a
  /// different shortcut replaces it and repeats of the same one pulse the
  /// existing box. When false a short stack of recent distinct shortcuts is
  /// shown (repeats still merge into one box).
  final bool singleBox;

  /// Timestamps (microseconds) of individual key events the user has turned
  /// OFF from the timeline. Disabled events are excluded from the on-video
  /// overlay and export, but their bar stays on the timeline (greyed) so it
  /// can be re-enabled. Toggling a coalesced bar flips all its member events.
  final Set<int> disabledKeys;

  /// Whether the event captured at [timestampMicros] is enabled (shown).
  bool isKeyEnabled(int timestampMicros) =>
      !disabledKeys.contains(timestampMicros);

  /// Whether an event of the given [kind] should be displayed under the
  /// current settings. Plain typing is always hidden; single keys depend on
  /// [showSingleKeyShortcuts]; real shortcuts always show.
  bool shouldDisplay(KeystrokeKind kind) => switch (kind) {
    KeystrokeKind.shortcut => true,
    KeystrokeKind.singleKey => showSingleKeyShortcuts,
    KeystrokeKind.typing => false,
  };

  KeystrokeOverlaySettings copyWith({
    bool? enabled,
    KeystrokePosition? position,
    double? labelScale,
    double? fadeSecs,
    bool? showSingleKeyShortcuts,
    bool? showTimeline,
    bool? singleBox,
    Set<int>? disabledKeys,
  }) => KeystrokeOverlaySettings(
    enabled: enabled ?? this.enabled,
    position: position ?? this.position,
    labelScale: labelScale ?? this.labelScale,
    fadeSecs: fadeSecs ?? this.fadeSecs,
    showSingleKeyShortcuts:
        showSingleKeyShortcuts ?? this.showSingleKeyShortcuts,
    showTimeline: showTimeline ?? this.showTimeline,
    singleBox: singleBox ?? this.singleBox,
    disabledKeys: disabledKeys ?? this.disabledKeys,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'position': position.name,
    'labelScale': labelScale,
    'fadeSecs': fadeSecs,
    'showSingleKeyShortcuts': showSingleKeyShortcuts,
    'showTimeline': showTimeline,
    'singleBox': singleBox,
    'disabledKeys': disabledKeys.toList(),
  };

  factory KeystrokeOverlaySettings.fromJson(Map<String, dynamic> json) {
    final pos = KeystrokePosition.values
        .where((v) => v.name == json['position'])
        .firstOrNull;
    return KeystrokeOverlaySettings(
      enabled: json['enabled'] as bool? ?? false,
      position: pos ?? KeystrokePosition.centerBottom,
      labelScale:
          (json['labelScale'] as num?)?.toDouble() ?? defaultLabelScale,
      fadeSecs: (json['fadeSecs'] as num?)?.toDouble() ?? 2.0,
      showSingleKeyShortcuts:
          json['showSingleKeyShortcuts'] as bool? ?? false,
      showTimeline: json['showTimeline'] as bool? ?? true,
      singleBox: json['singleBox'] as bool? ?? false,
      disabledKeys:
          (json['disabledKeys'] as List?)?.map((e) => e as int).toSet() ??
              const <int>{},
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeystrokeOverlaySettings &&
          other.enabled == enabled &&
          other.position == position &&
          other.labelScale == labelScale &&
          other.fadeSecs == fadeSecs &&
          other.showSingleKeyShortcuts == showSingleKeyShortcuts &&
          other.showTimeline == showTimeline &&
          other.singleBox == singleBox &&
          other.disabledKeys.length == disabledKeys.length &&
          other.disabledKeys.containsAll(disabledKeys);

  @override
  int get hashCode => Object.hash(
    enabled,
    position,
    labelScale,
    fadeSecs,
    showSingleKeyShortcuts,
    showTimeline,
    singleBox,
    Object.hashAllUnordered(disabledKeys),
  );
}
