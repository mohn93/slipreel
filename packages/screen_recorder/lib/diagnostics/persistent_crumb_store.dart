import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/breadcrumbs.dart';

import 'pii_scrubber.dart';

/// The trail a crashed session left behind, read at next launch.
class PersistedSession {
  const PersistedSession({
    required this.sessionId,
    required this.breadcrumbs,
    this.activity,
  });
  final String sessionId;
  final List<String> breadcrumbs;
  final Map<String, Object?>? activity;
}

/// Mirrors the in-memory breadcrumb ring plus a small "current activity" record
/// to `session.json`, scrubbed and throttled, so a full-app crash leaves a trail
/// for the next-launch scanner. Deleting the file on clean exit is what marks an
/// unclean crash: a surviving file means the app died mid-session.
///
/// Gated by `enabled` (`shareDiagnostics`): disabled means never write, and
/// delete any file that exists.
class PersistentCrumbStore {
  PersistentCrumbStore({
    required this.path,
    required this.sessionId,
    required Breadcrumbs breadcrumbs,
    required PiiScrubber scrubber,
    required bool enabled,
    DateTime Function() now = DateTime.now,
    this.flushInterval = const Duration(seconds: 2),
  })  : _breadcrumbs = breadcrumbs,
        _scrubber = scrubber,
        _enabled = enabled,
        _now = now;

  final String path;
  final String sessionId;
  final Breadcrumbs _breadcrumbs;
  final PiiScrubber _scrubber;
  final bool _enabled;
  final DateTime Function() _now;
  final Duration flushInterval;

  Map<String, Object?>? _activity;
  String? _lastWritten; // serialized payload of the last successful write
  Timer? _timer;

  PersistedSession? readPrevious() {
    if (!_enabled) return null;
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final crumbs = (json['breadcrumbs'] as List?)?.cast<String>() ?? const [];
      final activity = (json['activity'] as Map?)?.cast<String, Object?>();
      return PersistedSession(
        sessionId: json['session_id']?.toString() ?? 'unknown',
        breadcrumbs: crumbs,
        activity: activity,
      );
    } catch (_) {
      return null;
    }
  }

  void setActivity(Map<String, Object?>? activity) => _activity = activity;

  void start() {
    if (!_enabled) return;
    _timer ??= Timer.periodic(flushInterval, (_) => writeIfDirty());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void flushNow() => writeIfDirty();

  void writeIfDirty() {
    if (!_enabled) return;
    try {
      final payload = _serialize();
      if (payload == _lastWritten) return; // nothing changed
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(payload, flush: true);
      _lastWritten = payload;
    } catch (_) {
      // Best-effort: persisting crumbs must never break the app.
    }
  }

  void clearOnCleanExit() {
    stop();
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    _lastWritten = null;
  }

  String _serialize() {
    final crumbs = _scrubber.scrubAll(_breadcrumbs.snapshot());
    final activity =
        _activity?.map((k, v) => MapEntry(k, _scrubValue(v)));
    return jsonEncode({
      'session_id': sessionId,
      'launched_at': _now().toUtc().toIso8601String(),
      'breadcrumbs': crumbs,
      if (activity != null) 'activity': activity,
    });
  }

  Object? _scrubValue(Object? v) {
    if (v is String) return _scrubber.scrub(v);
    if (v is Map) return v.map((k, val) => MapEntry(k, _scrubValue(val)));
    if (v is List) return v.map(_scrubValue).toList();
    return v;
  }
}
