import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/utils/app_logger.dart';

/// App-level sidecar that persists last-used `ExportSettings` to a single
/// JSON file under `getApplicationSupportDirectory()`.
///
/// `load()` returns the saved settings or [ExportSettings.defaults()] on
/// missing/corrupt files. Throws [FormatException] when schema version is
/// in the future (downgrades are explicit-fail rather than silent-data-loss).
///
/// Writes are atomic (write to `*.tmp`, then rename) and serialized through
/// an internal mutation queue, ensuring the on-disk file never sees an
/// interleaved half-write.
class ExportSettingsStore {
  ExportSettingsStore({required this.filePath});

  final String filePath;

  /// Resolve the production path: `<appSupport>/screenflow_studio/export_settings.json`.
  /// Uses `path_provider`'s `getApplicationSupportDirectory()`. Creates
  /// the parent directory if missing.
  static Future<ExportSettingsStore> resolveDefault() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory('${appSupport.path}/screenflow_studio');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final filePath = '${dir.path}/export_settings.json';
    return ExportSettingsStore(filePath: filePath);
  }

  static const int _currentSchemaVersion = 1;

  /// Load. Returns [ExportSettings.defaults()] when file is missing or
  /// the JSON is unparseable. Logs a warning on corrupt content (don't
  /// throw — the user shouldn't see "your prefs are broken" surfaced).
  /// Throws [FormatException] when schema version is in the future
  /// (downgrades are explicit-fail rather than silent-data-loss).
  Future<ExportSettings> load() async {
    final f = File(filePath);
    if (!await f.exists()) {
      return ExportSettings.defaults();
    }
    try {
      final text = await f.readAsString();
      if (text.trim().isEmpty) {
        return ExportSettings.defaults();
      }
      final json = jsonDecode(text) as Map<String, dynamic>;

      final schemaVersion = json['schemaVersion'] as int?;
      if (schemaVersion == null || schemaVersion < 1) {
        AppLogger.ui.w(
          'ExportSettingsStore: invalid or missing schema version — falling back to defaults',
        );
        return ExportSettings.defaults();
      }

      if (schemaVersion > _currentSchemaVersion) {
        throw FormatException(
          'ExportSettingsStore: unsupported schema version $schemaVersion (max supported: $_currentSchemaVersion)',
        );
      }

      final settingsJson = json['settings'] as Map<String, dynamic>?;
      if (settingsJson == null) {
        AppLogger.ui.w(
          'ExportSettingsStore: missing settings field — falling back to defaults',
        );
        return ExportSettings.defaults();
      }

      return ExportSettings.fromJson(settingsJson);
    } catch (e, stack) {
      if (e is FormatException && e.message.startsWith('ExportSettingsStore:')) {
        rethrow;
      }
      AppLogger.ui.w(
        'ExportSettingsStore: failed to load, using defaults',
        error: e,
        stackTrace: stack,
      );
      return ExportSettings.defaults();
    }
  }

  Future<void> _writeQueue = Future.value();
  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    _writeQueue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// Save atomically. Concurrent saves are serialized via an internal
  /// mutation queue so the on-disk file never sees an interleaved
  /// half-write.
  Future<void> save(ExportSettings settings) {
    return _enqueue(() async {
      final tmp = File('$filePath.tmp');
      try {
        final json = {
          'schemaVersion': _currentSchemaVersion,
          'settings': settings.toJson(),
        };
        await tmp.writeAsString(jsonEncode(json), flush: true);
        await tmp.rename(filePath);
      } catch (e, stack) {
        AppLogger.ui.e(
          'ExportSettingsStore: save to $filePath failed',
          error: e,
          stackTrace: stack,
        );
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        rethrow;
      }
    });
  }
}
