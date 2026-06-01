import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';

/// JSON sidecar at `<applicationSupportDirectory>/app_palette.json`
/// holding the user's last picked palette. Mirrors `RecordingSettingsStore`.
class AppPaletteStore {
  AppPaletteStore({required this.path});
  final String path;

  static Future<AppPaletteStore> resolveDefault() async {
    final dir = await getApplicationSupportDirectory();
    return AppPaletteStore(path: p.join(dir.path, 'app_palette.json'));
  }

  /// Returns the persisted palette or `null` if the file is missing,
  /// unreadable, or holds an unknown value. Never throws.
  Future<PaletteId?> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final name = json['paletteId'];
      if (name is! String) return null;
      for (final id in PaletteId.values) {
        if (id.name == name) return id;
      }
      return null;
    } catch (e, st) {
      AppLogger.platform.w('AppPaletteStore.load failed; falling back',
          error: e, stackTrace: st);
      return null;
    }
  }

  Future<void> save(PaletteId id) async {
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode({'paletteId': id.name}));
  }
}
