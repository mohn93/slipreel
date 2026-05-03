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
  static const int _currentSchemaVersion = 1;
  Future<void> _writeQueue = Future.value();

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

  /// Load. Returns [ExportSettings.defaults()] when file is missing or
  /// the JSON is unparseable. Logs a warning on corrupt content (don't
  /// throw — the user shouldn't see "your prefs are broken" surfaced).
  /// Throws [FormatException] when schema version is in the future
  /// (downgrades are explicit-fail rather than silent-data-loss).
  Future<ExportSettings> load() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return ExportSettings.defaults();
    }

    Map<String, dynamic>? json;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return ExportSettings.defaults();
      }
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      AppLogger.ui.w(
        'ExportSettingsStore: failed to parse $filePath, using defaults: $e',
      );
      return ExportSettings.defaults();
    }

    final v = json['schemaVersion'];
    if (v is int && v > _currentSchemaVersion) {
      throw FormatException(
        'ExportSettingsStore: unsupported schema version $v in $filePath '
        '(max supported: $_currentSchemaVersion)',
      );
    }
    if (v != _currentSchemaVersion) {
      AppLogger.ui.w(
        'ExportSettingsStore: missing/old schemaVersion ($v) in $filePath, using defaults',
      );
      return ExportSettings.defaults();
    }

    try {
      return ExportSettings.fromJson(json['settings'] as Map<String, dynamic>);
    } catch (e) {
      AppLogger.ui.w(
        'ExportSettingsStore: failed to decode settings in $filePath, using defaults: $e',
      );
      return ExportSettings.defaults();
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    // Swallow errors so a single failed save doesn't poison the chain.
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
        // Best-effort cleanup; ignore errors here since the rename
        // may have already moved the tmp file out from under us.
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        rethrow;
      }
    });
  }
}
