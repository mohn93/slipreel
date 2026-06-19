import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/app_logger.dart';

/// Global, app-wide preferences (not per-project). Grows over time.
class GlobalPreferences {
  const GlobalPreferences({this.defaultSaveLocation});

  /// Absolute folder path used as the default recording/export destination.
  /// `null` means "ask each time / use the OS Documents directory".
  final String? defaultSaveLocation;

  GlobalPreferences copyWith({
    String? defaultSaveLocation,
    bool clearSaveLocation = false,
  }) =>
      GlobalPreferences(
        defaultSaveLocation:
            clearSaveLocation ? null : (defaultSaveLocation ?? this.defaultSaveLocation),
      );

  Map<String, dynamic> toJson() => {
        if (defaultSaveLocation != null) 'defaultSaveLocation': defaultSaveLocation,
      };

  static const defaults = GlobalPreferences();

  static GlobalPreferences fromJson(Map<String, dynamic> json) {
    final raw = json['defaultSaveLocation'];
    return GlobalPreferences(
      defaultSaveLocation: raw is String && raw.isNotEmpty ? raw : null,
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
