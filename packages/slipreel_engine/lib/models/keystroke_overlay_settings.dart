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

/// Visual size of keystroke pill badges.
enum KeystrokeSize {
  small,
  medium,
  large;

  String get label => switch (this) {
    small => 'S',
    medium => 'M',
    large => 'L',
  };

  double get fontSize => switch (this) {
    small => 13,
    medium => 16,
    large => 20,
  };

  double get horizontalPadding => switch (this) {
    small => 10,
    medium => 14,
    large => 18,
  };

  double get verticalPadding => switch (this) {
    small => 5,
    medium => 7,
    large => 10,
  };
}

/// Per-project configuration for the keystroke overlay that appears on
/// the canvas during playback and export.
class KeystrokeOverlaySettings {
  const KeystrokeOverlaySettings({
    this.enabled = false,
    this.position = KeystrokePosition.centerBottom,
    this.size = KeystrokeSize.medium,
    this.fadeSecs = 2.0,
  });

  /// Whether to render the overlay at all. Toggled in the Shortcuts tab.
  final bool enabled;

  /// Canvas anchor for the badge stack.
  final KeystrokePosition position;

  /// Visual size of individual keystroke pills.
  final KeystrokeSize size;

  /// Seconds each keystroke badge stays visible (including fade-out).
  final double fadeSecs;

  KeystrokeOverlaySettings copyWith({
    bool? enabled,
    KeystrokePosition? position,
    KeystrokeSize? size,
    double? fadeSecs,
  }) => KeystrokeOverlaySettings(
    enabled: enabled ?? this.enabled,
    position: position ?? this.position,
    size: size ?? this.size,
    fadeSecs: fadeSecs ?? this.fadeSecs,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'position': position.name,
    'size': size.name,
    'fadeSecs': fadeSecs,
  };

  factory KeystrokeOverlaySettings.fromJson(Map<String, dynamic> json) {
    final pos = KeystrokePosition.values
        .where((v) => v.name == json['position'])
        .firstOrNull;
    final sz = KeystrokeSize.values
        .where((v) => v.name == json['size'])
        .firstOrNull;
    return KeystrokeOverlaySettings(
      enabled: json['enabled'] as bool? ?? false,
      position: pos ?? KeystrokePosition.centerBottom,
      size: sz ?? KeystrokeSize.medium,
      fadeSecs: (json['fadeSecs'] as num?)?.toDouble() ?? 2.0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeystrokeOverlaySettings &&
          other.enabled == enabled &&
          other.position == position &&
          other.size == size &&
          other.fadeSecs == fadeSecs;

  @override
  int get hashCode => Object.hash(enabled, position, size, fadeSecs);
}
