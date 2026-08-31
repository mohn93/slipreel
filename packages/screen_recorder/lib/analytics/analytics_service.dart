import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slipreel_engine/utils/app_logger.dart';

import 'analytics_config.dart';
import 'analytics_event.dart';
import 'analytics_queue_store.dart';

/// Fire-and-forget product analytics for the desktop app.
///
/// Design goals (see docs/analytics.md):
///   - Never breaks or blocks the app. Every path is best-effort; failures are
///     logged and swallowed, and a failed send just stays queued for later.
///   - Privacy-respecting. Opt-out (on by default) via [setEnabled]; when the
///     user opts out the buffered queue is discarded, not sent. Only cheap,
///     non-identifying properties are ever captured (the callers' job).
///   - Offline-tolerant. Events are buffered in memory and mirrored to a
///     bounded on-disk queue, then delivered to PostHog's /batch/ endpoint.
///
/// The whole thing no-ops unless a real project key was baked in
/// ([AnalyticsConfig.isConfigured]).
class AnalyticsService {
  AnalyticsService({
    required AnalyticsQueueStore store,
    required String distinctId,
    required bool enabled,
    http.Client? client,
    String projectKey = AnalyticsConfig.projectKey,
    String? host,
    Map<String, Object?> superProperties = const {},
    Duration flushDebounce = const Duration(seconds: 5),
    DateTime Function() now = DateTime.now,
  })  : _store = store,
        _distinctId = distinctId,
        _enabled = enabled,
        _client = client ?? http.Client(),
        _projectKey = projectKey,
        _host = host ?? AnalyticsConfig.hostResolved,
        _superProperties = superProperties,
        _flushDebounce = flushDebounce,
        _now = now;

  final AnalyticsQueueStore _store;
  String _distinctId; // mutable: becomes the user id after identify()
  final http.Client _client;
  final String _projectKey;
  final String _host;
  final Map<String, Object?> _superProperties;
  final Duration _flushDebounce;
  final DateTime Function() _now;

  bool _enabled;

  /// True only when a real project key is present. Gates all sending, so an
  /// unconfigured build (or a test with no key) no-ops.
  bool get _configured => _projectKey.startsWith('phc_');
  final List<AnalyticsEvent> _queue = [];
  bool _flushing = false;
  Timer? _flushTimer;

  bool get enabled => _enabled;

  /// Loads events left over from a previous run into the in-memory queue. Call
  /// once at startup. Delivery is not forced here; the `app_opened` capture
  /// that follows in main() schedules a flush that carries these along too.
  Future<void> load() async {
    if (!_configured) return;
    _queue.addAll(await _store.load());
  }

  /// Records an event. Cheap and synchronous from the caller's view: it
  /// enqueues, mirrors to disk, and schedules a debounced flush.
  void capture(String event, {Map<String, Object?>? properties}) {
    if (!_enabled || !_configured) return;
    _queue.add(AnalyticsEvent(
      name: event,
      timestamp: _now(),
      properties: {..._superProperties, ...?properties},
    ));
    unawaited(_store.save(_queue));
    _scheduleFlush();
  }

  /// Attribution: link this install's anonymous, device-keyed person to a
  /// stable [userId] (the entitlement token's `sub`) so app + web events unify
  /// into one PostHog person. [setProps] sets person properties. No-ops when
  /// disabled/unconfigured or already identified as [userId].
  void identify(String userId, {Map<String, Object?>? setProps}) {
    if (!_enabled || !_configured) return;
    if (userId.isEmpty || _distinctId == userId) return;
    final anonId = _distinctId;
    _distinctId = userId; // the $identify below (and later events) use the new id
    _queue.add(AnalyticsEvent(
      name: r'$identify',
      timestamp: _now(),
      properties: {
        r'$anon_distinct_id': anonId,
        if (setProps != null && setProps.isNotEmpty) r'$set': setProps,
      },
    ));
    unawaited(_store.save(_queue));
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDebounce, () => unawaited(flush()));
  }

  /// Delivers everything currently queued in one PostHog /batch/ request. On
  /// failure the queue is left intact for the next attempt.
  Future<void> flush() async {
    if (_flushing || !_enabled || !_configured) return;
    if (_queue.isEmpty) return;
    _flushing = true;
    _flushTimer?.cancel();
    final sent = List<AnalyticsEvent>.of(_queue);
    try {
      final res = await _client
          .post(
            Uri.parse('$_host/batch/'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'api_key': _projectKey,
              'historical_migration': false,
              'batch': sent.map((e) => e.toBatchItem(_distinctId)).toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        // Remove exactly what we sent; events captured during the POST stay.
        final delivered = Set<AnalyticsEvent>.identity()..addAll(sent);
        _queue.removeWhere(delivered.contains);
        await _store.save(_queue);
      } else {
        AppLogger.platform.w('analytics flush: HTTP ${res.statusCode}; will retry');
      }
    } catch (e) {
      // Offline / timeout / DNS — keep the queue and try again next time.
      AppLogger.platform.d('analytics flush deferred: $e');
    } finally {
      _flushing = false;
      if (_enabled && _queue.isNotEmpty) _scheduleFlush();
    }
  }

  /// Toggles capture. Turning it off discards buffered events (opt-out means
  /// "don't send what I did before either"); turning it on starts fresh.
  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) {
      _flushTimer?.cancel();
      _queue.clear();
      await _store.clear();
    }
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flush();
    _client.close();
  }
}

/// App-wide analytics. Overridden in `main()` with the instance initialized at
/// startup. The default throws so a missing override is caught in development.
final analyticsServiceProvider = Provider<AnalyticsService>(
  (ref) => throw UnimplementedError('Override analyticsServiceProvider in main()'),
);

/// Widget-friendly capture that no-ops if the provider isn't overridden — e.g.
/// a widget test that pumps a screen without wiring analytics. Use this from
/// `initState`/build paths so instrumentation can't crash a screen.
extension AnalyticsWidgetRef on WidgetRef {
  void captureAnalytics(String event, {Map<String, Object?>? properties}) {
    try {
      read(analyticsServiceProvider).capture(event, properties: properties);
    } catch (_) {
      /* analytics not wired in this context */
    }
  }
}
