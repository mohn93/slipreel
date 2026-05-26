/// Which apps' system audio to capture.
enum SystemAudioMode { allApps, selectedApps }

/// A system-audio capture selection. `null` (absence of this config) means
/// "don't record system audio". For [SystemAudioMode.allApps], [bundleIds] is
/// empty; for [SystemAudioMode.selectedApps] it holds the chosen app bundle ids.
class SystemAudioConfig {
  final SystemAudioMode mode;
  final List<String> bundleIds;

  const SystemAudioConfig({required this.mode, this.bundleIds = const []});

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'bundleIds': bundleIds,
      };

  factory SystemAudioConfig.fromJson(Map<String, dynamic> json) =>
      SystemAudioConfig(
        mode: SystemAudioMode.values.byName(json['mode'] as String),
        bundleIds:
            (json['bundleIds'] as List?)?.cast<String>() ?? const <String>[],
      );

  SystemAudioConfig copyWith({SystemAudioMode? mode, List<String>? bundleIds}) =>
      SystemAudioConfig(
        mode: mode ?? this.mode,
        bundleIds: bundleIds ?? this.bundleIds,
      );

  @override
  bool operator ==(Object other) =>
      other is SystemAudioConfig &&
      other.mode == mode &&
      _setEquals(other.bundleIds, bundleIds);

  @override
  int get hashCode => Object.hash(mode, Object.hashAllUnordered(bundleIds));

  @override
  String toString() => 'SystemAudioConfig($mode, ${bundleIds.length} apps)';

  static bool _setEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }
}

/// Result of the native system-audio menu. [cancelled] true means the user
/// dismissed it (no change). When not cancelled, [config] is the new selection,
/// or null for "Don't record system audio".
class SystemAudioMenuResult {
  final bool cancelled;
  final SystemAudioConfig? config;

  const SystemAudioMenuResult({required this.cancelled, this.config});

  factory SystemAudioMenuResult.fromJson(Map<String, dynamic> json) {
    final c = json['config'];
    return SystemAudioMenuResult(
      cancelled: json['cancelled'] as bool? ?? false,
      config: c == null
          ? null
          : SystemAudioConfig.fromJson(Map<String, dynamic>.from(c as Map)),
    );
  }
}
