/// Per-track volume settings for the two possible recording audio tracks
/// (microphone, system). Gains are a percentage: 0 = silent, 100 = unchanged,
/// up to 200 = ~+6 dB boost. Stored by role; the physical track index is
/// resolved at export from a probe. Mute preserves the gain value.
class AudioMix {
  final int micGainPercent;
  final bool micMuted;
  final int systemGainPercent;
  final bool systemMuted;

  const AudioMix({
    int micGainPercent = 100,
    this.micMuted = false,
    int systemGainPercent = 100,
    this.systemMuted = false,
  })  : micGainPercent =
            micGainPercent < 0 ? 0 : (micGainPercent > 200 ? 200 : micGainPercent),
        systemGainPercent = systemGainPercent < 0
            ? 0
            : (systemGainPercent > 200 ? 200 : systemGainPercent);

  Map<String, dynamic> toJson() => {
        'micGainPercent': micGainPercent,
        'micMuted': micMuted,
        'systemGainPercent': systemGainPercent,
        'systemMuted': systemMuted,
      };

  factory AudioMix.fromJson(Map<String, dynamic> json) => AudioMix(
        micGainPercent: (json['micGainPercent'] as num?)?.round() ?? 100,
        micMuted: json['micMuted'] as bool? ?? false,
        systemGainPercent: (json['systemGainPercent'] as num?)?.round() ?? 100,
        systemMuted: json['systemMuted'] as bool? ?? false,
      );

  AudioMix copyWith({
    int? micGainPercent,
    bool? micMuted,
    int? systemGainPercent,
    bool? systemMuted,
  }) =>
      AudioMix(
        micGainPercent: micGainPercent ?? this.micGainPercent,
        micMuted: micMuted ?? this.micMuted,
        systemGainPercent: systemGainPercent ?? this.systemGainPercent,
        systemMuted: systemMuted ?? this.systemMuted,
      );

  @override
  bool operator ==(Object other) =>
      other is AudioMix &&
      other.micGainPercent == micGainPercent &&
      other.micMuted == micMuted &&
      other.systemGainPercent == systemGainPercent &&
      other.systemMuted == systemMuted;

  @override
  int get hashCode =>
      Object.hash(micGainPercent, micMuted, systemGainPercent, systemMuted);
}
