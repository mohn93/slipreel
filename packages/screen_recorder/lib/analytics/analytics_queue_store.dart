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
      AppLogger.platform.w(
        'AnalyticsQueueStore.load failed; starting empty',
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  Future<void> _writes = Future.value();
  Future<void> _serialize(Future<void> Function() work) {
    final next = _writes.then((_) => work());
    _writes = next.catchError((Object _) {});
    return next;
  }

  /// Atomic and serialized. Failure is reported so feedback cannot claim
  /// durable offline delivery when the disk write failed.
  Future<void> save(List<AnalyticsEvent> events) {
    final trimmed = events.length > maxEvents
        ? events.sublist(events.length - maxEvents)
        : List.of(events);
    final encoded = jsonEncode(trimmed.map((e) => e.toJson()).toList());
    return _serialize(() async {
      final tmp = File('$path.tmp');
      try {
        await tmp.parent.create(recursive: true);
        await tmp.writeAsString(encoded, flush: true);
        await tmp.rename(path);
      } finally {
        if (await tmp.exists()) await tmp.delete();
      }
    });
  }

  Future<void> clear() => _serialize(() async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  });
}
