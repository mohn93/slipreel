import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/app_logger.dart';

import 'analytics_event.dart';

/// JSON sidecar under getApplicationSupportDirectory() holding events that have
/// not yet been delivered (the app was offline, or a flush failed). Mirrors
/// [GlobalPreferencesStore]. Bounded so an app that is offline for a long time
/// cannot grow the file without limit — oldest events are dropped first.
class AnalyticsQueueStore {
  AnalyticsQueueStore({required this.path, this.maxEvents = 500});

  final String path;
  final int maxEvents;

  Future<List<AnalyticsEvent>> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return [];
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AnalyticsEvent.fromJson)
          .whereType<AnalyticsEvent>()
          .toList();
    } catch (e, st) {
      AppLogger.platform
          .w('AnalyticsQueueStore.load failed; starting empty', error: e, stackTrace: st);
      return [];
    }
  }

  /// Persists the queue, keeping only the newest [maxEvents]. Best-effort:
  /// analytics must never break the app, so failures are logged and swallowed.
  Future<void> save(List<AnalyticsEvent> events) async {
    try {
      final trimmed =
          events.length > maxEvents ? events.sublist(events.length - maxEvents) : events;
      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode(trimmed.map((e) => e.toJson()).toList()));
    } catch (e, st) {
      AppLogger.platform
          .w('AnalyticsQueueStore.save failed; dropping', error: e, stackTrace: st);
    }
  }

  /// Removes the persisted queue (used when the user opts out).
  Future<void> clear() async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (_) {
      /* best-effort */
    }
  }
}
