import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/app_logger.dart';

/// Global, app-wide preferences (not per-project). Grows over time.
class GlobalPreferences {
  const GlobalPreferences({
    this.defaultSaveLocation,
    this.shareAnalytics = true,
    this.shareDiagnostics = true,
  });

  /// Absolute folder path used as the default recording/export destination.
  /// `null` means "ask each time / use the OS Documents directory".
  final String? defaultSaveLocation;

  /// Whether anonymous usage analytics may be sent. Opt-out: on by default,
  /// flipped off from Settings → Privacy. Absent in an older prefs file means
  /// "on" (existing users keep the default).
  final bool shareAnalytics;

  /// Whether diagnostic data may be sent. Opt-out: on by default,
  /// flipped off from Settings → Privacy. Absent in an older prefs file means
  /// "on" (existing users keep the default).
  final bool shareDiagnostics;

  GlobalPreferences copyWith({
    String? defaultSaveLocation,
    bool clearSaveLocation = false,
    bool? shareAnalytics,
    bool? shareDiagnostics,
  }) =>
      GlobalPreferences(
        defaultSaveLocation:
            clearSaveLocation ? null : (defaultSaveLocation ?? this.defaultSaveLocation),
        shareAnalytics: shareAnalytics ?? this.shareAnalytics,
        shareDiagnostics: shareDiagnostics ?? this.shareDiagnostics,
      );

  Map<String, dynamic> toJson() => {
        if (defaultSaveLocation != null) 'defaultSaveLocation': defaultSaveLocation,
        'shareAnalytics': shareAnalytics,
        'shareDiagnostics': shareDiagnostics,
      };

  static const defaults = GlobalPreferences();

  static GlobalPreferences fromJson(Map<String, dynamic> json) {
    final raw = json['defaultSaveLocation'];
    final analytics = json['shareAnalytics'];
    final diagnostics = json['shareDiagnostics'];
    return GlobalPreferences(
      defaultSaveLocation: raw is String && raw.isNotEmpty ? raw : null,
      shareAnalytics: analytics is bool ? analytics : true,
      shareDiagnostics: diagnostics is bool ? diagnostics : true,
    );
  }
}

/// JSON sidecar under getApplicationSupportDirectory(). Mirrors
/// [RecordingSettingsStore].
class GlobalPreferencesStore {
  GlobalPreferencesStore({required this.path});
  final String path;

  Future<GlobalPreferences> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return GlobalPreferences.defaults;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return GlobalPreferences.fromJson(json);
    } catch (e, st) {
      AppLogger.platform.w('GlobalPreferencesStore.load failed; falling back',
          error: e, stackTrace: st);
      return GlobalPreferences.defaults;
    }
  }

  Future<void> save(GlobalPreferences prefs) async {
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(prefs.toJson()));
  }
}
