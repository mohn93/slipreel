import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

import '../analytics/posthog_sink.dart';
import 'exception_event_builder.dart';
import 'native_crash_report.dart';
import 'pii_scrubber.dart';

/// Sends Dart exceptions to PostHog Error Tracking, gated by the user's
/// diagnostics opt-out. Best-effort like analytics: capture never throws.
class DiagnosticsService {
  DiagnosticsService({
    required PostHogSink sink,
    required ExceptionEventBuilder builder,
    required Breadcrumbs breadcrumbs,
    required PiiScrubber scrubber,
    required bool enabled,
    this.maxPerSession = 50,
    this.dedupeWindow = const Duration(seconds: 30),
    DateTime Function() now = DateTime.now,
  })  : _sink = sink,
        _builder = builder,
        _breadcrumbs = breadcrumbs,
        _scrubber = scrubber,
        _enabled = enabled,
        _now = now;

  final PostHogSink _sink;
  final ExceptionEventBuilder _builder;
  final Breadcrumbs _breadcrumbs;
  final PiiScrubber _scrubber;
  final int maxPerSession;
  final Duration dedupeWindow;
  final DateTime Function() _now;

  bool _enabled;
  int _sessionCount = 0;
  final Map<String, DateTime> _lastSeen = {};

  bool get enabled => _enabled;

  Future<void> load() async {
    if (_enabled) await _sink.load();
  }

  void captureException(Object error, StackTrace? stack,
      {bool handled = true,
      Map<String, Object?>? context,
      String? messageOverride}) {
    try {
      if (!_enabled || !_sink.isConfigured) return;
      if (_sessionCount >= maxPerSession) return;
      final fp = _builder.fingerprintFor(error, stack);
      final last = _lastSeen[fp];
      final t = _now();
      if (last != null && t.difference(last) < dedupeWindow) return;
      _lastSeen[fp] = t;
      _sessionCount++;
      final crumbs = _scrubber.scrubAll(_breadcrumbs.snapshot());
      _sink.enqueue(_builder.fromDart(error, stack,
          handled: handled,
          breadcrumbs: crumbs,
          context: context,
          messageOverride: messageOverride,
          now: t));
    } catch (_) {
      // Best-effort: capturing an exception must never break the app.
    }
  }

  /// Forwards a parsed native crash (from the next-launch scanner) as a native
  /// `$exception`. Same gating, cap, and dedupe as [captureException]; the
  /// crumbs/activity/session id belong to the crashed (previous) session.
  void captureNativeCrash(NativeCrashReport report,
      {List<String> breadcrumbs = const [],
      Map<String, Object?>? activity,
      String? sessionId}) {
    try {
      if (!_enabled || !_sink.isConfigured) return;
      if (_sessionCount >= maxPerSession) return;
      final fp = _builder.fingerprintForNative(report);
      final last = _lastSeen[fp];
      final t = _now();
      if (last != null && t.difference(last) < dedupeWindow) return;
      _lastSeen[fp] = t;
      _sessionCount++;
      // Stamp the event at the CRASH's own time, not this scan's time (which
      // could be days later). `fromNative`'s `now ?? report.crashedAt ??
      // DateTime.now()` fallback still does the right thing when crashedAt is
      // null; `t` above stays the in-memory dedupe clock only.
      _sink.enqueue(_builder.fromNative(report,
          breadcrumbs: breadcrumbs,
          activity: activity,
          sessionId: sessionId,
          now: report.crashedAt));
    } catch (_) {
      // Best-effort: forwarding a native crash must never break the app.
    }
  }

  void setDistinctId(String id) => _sink.setDistinctId(id);

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) await _sink.clear();
  }

  Future<void> flush() => _sink.flush();
  Future<void> dispose() => _sink.dispose();
}

final diagnosticsServiceProvider = Provider<DiagnosticsService>(
  (ref) => throw UnimplementedError('Override diagnosticsServiceProvider in main()'),
);
