import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder/utils/app_logger.dart';

/// App-level sidecar that persists the most recent observed
/// `realtimeMultiple` from an export, normalized to
/// `kBaselineFrameRate` + `kBaselineAreaPixels` so a single number is
/// meaningful regardless of which resolution / fps was actually
/// exported. The dialog reads this on open and feeds it to
/// [ExportEstimator] as the starting `lastRealtimeMultiplier`, so
/// estimates self-improve as the user does more exports.
///
/// Mirrors the atomic-write + mutation-queue patterns of
/// `ExportSettingsStore`. Sibling file rather than an extension of
/// settings because user-chosen settings and runtime measurements are
/// distinct concepts and conflating them invites confusion.
class ExportTelemetryStore {
  ExportTelemetryStore({required this.filePath});

  final String filePath;
  static const int _currentSchemaVersion = 1;
  Future<void> _writeQueue = Future.value();

  /// Resolve the production path:
  /// `<appSupport>/slipreel/export_telemetry.json`. Creates
  /// the parent directory if missing.
  static Future<ExportTelemetryStore> resolveDefault() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory('${appSupport.path}/slipreel');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return ExportTelemetryStore(
      filePath: '${dir.path}/export_telemetry.json',
    );
  }

  /// Load the persisted normalized multiplier. Returns null when the
  /// file is missing or unparseable so callers can fall back to their
  /// own default. Future schema versions throw [FormatException].
  Future<double?> loadRealtimeMultiplier() async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    Map<String, dynamic>? json;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      AppLogger.ui.w(
        'ExportTelemetryStore: failed to parse $filePath, ignoring: $e',
      );
      return null;
    }

    final v = json['schemaVersion'];
    if (v is int && v > _currentSchemaVersion) {
      throw FormatException(
        'ExportTelemetryStore: unsupported schema version $v in $filePath '
        '(max supported: $_currentSchemaVersion)',
      );
    }
    if (v != _currentSchemaVersion) {
      AppLogger.ui.w(
        'ExportTelemetryStore: missing/old schemaVersion ($v) in $filePath, ignoring',
      );
      return null;
    }

    final value = json['normalizedRealtimeMultiplier'];
    if (value is num && value > 0) return value.toDouble();
    return null;
  }

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    _writeQueue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// Save atomically; serialised via the mutation queue.
  Future<void> saveRealtimeMultiplier(double normalized) {
    return _enqueue(() async {
      final tmp = File('$filePath.tmp');
      try {
        final json = {
          'schemaVersion': _currentSchemaVersion,
          'normalizedRealtimeMultiplier': normalized,
        };
        await tmp.writeAsString(jsonEncode(json), flush: true);
        await tmp.rename(filePath);
      } catch (e, stack) {
        AppLogger.ui.e(
          'ExportTelemetryStore: save to $filePath failed',
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
