import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

import 'native_crash_report.dart';
import 'pii_scrubber.dart';

/// The trail a crashed session left behind, read at next launch.
class PersistedSession {
  const PersistedSession({
    required this.sessionId,
    required this.breadcrumbs,
    this.activity,
    this.launchedAt,
  });
  final String sessionId;
  final List<String> breadcrumbs;
  final Map<String, Object?>? activity;

  /// When the crashed session launched (from its `launched_at`). Used to
  /// time-bound crumb attribution: a crash report from BEFORE this time
  /// belongs to an earlier/backlog crash, not this session, so it must not
  /// inherit this session's trail. Null when the field was absent/unparseable.
  final DateTime? launchedAt;
}

/// Whether [report]'s crumb trail may be attached to [previous] (the crashed
/// session read at this launch). A report whose crash happened BEFORE the
/// session launched is an older/backlog crash — on first launch the crash dir
/// can hold weeks of unrelated `.ips` files — and must NOT inherit this
/// session's trail. Conservative on nulls: if either timestamp is unknown,
/// treat the report as backlog and do not attach.
bool crumbTrailAppliesTo(PersistedSession? previous, NativeCrashReport report) {
  final launchedAt = previous?.launchedAt;
  final crashedAt = report.crashedAt;
  if (previous == null || launchedAt == null || crashedAt == null) {
    return false;
  }
  return !crashedAt.isBefore(launchedAt);
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
        _launchedAt = now();

  final String path;
  final String sessionId;
  final Breadcrumbs _breadcrumbs;
  final PiiScrubber _scrubber;
  bool _enabled;
  // Captured once at construction, not re-read per write: `launched_at` is a
  // property of the session, not of the write. Keeping it fixed also lets the
  // dirty check in `writeIfDirty` work — a payload that varied with the clock
  // on every serialize would never compare equal across calls.
  final DateTime _launchedAt;
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
      // Materialize eagerly (not a lazy `.cast`): a wrong-typed element would
      // otherwise throw later, at iteration, outside this try/catch — a
      // malformed file must return null here, never throw.
      final crumbs = (json['breadcrumbs'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [];
      final rawActivity = json['activity'] as Map?;
      final activity =
          rawActivity == null ? null : Map<String, Object?>.from(rawActivity);
      final rawLaunchedAt = json['launched_at']?.toString();
      return PersistedSession(
        sessionId: json['session_id']?.toString() ?? 'unknown',
        breadcrumbs: crumbs,
        activity: activity,
        launchedAt:
            rawLaunchedAt == null ? null : DateTime.tryParse(rawLaunchedAt),
      );
    } catch (_) {
      return null;
    }
  }

  void setActivity(Map<String, Object?>? activity) => _activity = activity;

  /// Reacts to the user flipping `shareDiagnostics` mid-session. Opting out
  /// must immediately gate writes and delete any on-disk trail (spec §6:
  /// "off means silent") — opting back in resumes periodic persistence.
  void setEnabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) {
      clearOnCleanExit(); // stops the timer + deletes session.json
    } else {
      start(); // resume periodic persistence
    }
  }

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
      // Write via a temp file + rename so a crash mid-write can never leave
      // truncated JSON at `path` — that would read back as "no previous
      // session" and lose the very crash trail this store exists to keep.
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(payload, flush: true);
      tmp.renameSync(path);
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
      'launched_at': _launchedAt.toUtc().toIso8601String(),
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

final crumbStoreProvider = Provider<PersistentCrumbStore>(
  (ref) => throw UnimplementedError('Override crumbStoreProvider in main()'),
);
