/// A chosen microphone input and its capture options. `null` (absence of this
/// config) means "don't record microphone".
class MicrophoneConfig {
  /// Stable CoreAudio device UID, used to re-resolve the device at capture time.
  final String deviceUid;

  /// Human-readable device name, shown on the bar's mic control.
  final String deviceLabel;

  /// Enable AVAudioEngine voice processing (noise suppression + level normalize).
  final bool reduceNoise;

  /// Turn off automatic gain control. Only honored on macOS 14+.
  final bool disableAgc;

  const MicrophoneConfig({
    required this.deviceUid,
    required this.deviceLabel,
    this.reduceNoise = false,
    this.disableAgc = false,
  });

  Map<String, dynamic> toJson() => {
        'deviceUid': deviceUid,
        'deviceLabel': deviceLabel,
        'reduceNoise': reduceNoise,
        'disableAgc': disableAgc,
      };

  factory MicrophoneConfig.fromJson(Map<String, dynamic> json) => MicrophoneConfig(
        deviceUid: json['deviceUid'] as String,
        deviceLabel: json['deviceLabel'] as String,
        reduceNoise: json['reduceNoise'] as bool? ?? false,
        disableAgc: json['disableAgc'] as bool? ?? false,
      );

  MicrophoneConfig copyWith({
    String? deviceUid,
    String? deviceLabel,
    bool? reduceNoise,
    bool? disableAgc,
  }) =>
      MicrophoneConfig(
        deviceUid: deviceUid ?? this.deviceUid,
        deviceLabel: deviceLabel ?? this.deviceLabel,
        reduceNoise: reduceNoise ?? this.reduceNoise,
        disableAgc: disableAgc ?? this.disableAgc,
      );

  @override
  bool operator ==(Object other) =>
      other is MicrophoneConfig &&
      other.deviceUid == deviceUid &&
      other.deviceLabel == deviceLabel &&
      other.reduceNoise == reduceNoise &&
      other.disableAgc == disableAgc;

  @override
  int get hashCode => Object.hash(deviceUid, deviceLabel, reduceNoise, disableAgc);

  @override
  String toString() =>
      'MicrophoneConfig($deviceLabel, reduceNoise: $reduceNoise, disableAgc: $disableAgc)';
}

/// Result of the native microphone menu. [cancelled] true means the user
/// dismissed the menu (no change). When not cancelled, [config] is the new
/// selection, or null for "Don't record microphone".
class MicrophoneMenuResult {
  final bool cancelled;
  final MicrophoneConfig? config;

  const MicrophoneMenuResult({required this.cancelled, this.config});

  factory MicrophoneMenuResult.fromJson(Map<String, dynamic> json) {
    final c = json['config'];
    return MicrophoneMenuResult(
      cancelled: json['cancelled'] as bool? ?? false,
      config: c == null
          ? null
          : MicrophoneConfig.fromJson(Map<String, dynamic>.from(c as Map)),
    );
  }
}
