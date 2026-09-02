import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'analytics_config.dart';
import 'analytics_event.dart';
import 'analytics_queue_store.dart';
import 'posthog_sink.dart';

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
  })  : _enabled = enabled,
        _distinctId = distinctId,
        _superProperties = superProperties,
        _now = now,
        _sink = PostHogSink(
          store: store,
          distinctId: distinctId,
          projectKey: projectKey,
          host: host ?? AnalyticsConfig.hostResolved,
          client: client,
          flushDebounce: flushDebounce,
        );

  final PostHogSink _sink;
  String _distinctId; // mutable: becomes the user id after identify()
  final Map<String, Object?> _superProperties;
  final DateTime Function() _now;

  bool _enabled;

  bool get enabled => _enabled;

  /// Loads events left over from a previous run into the in-memory queue. Call
  /// once at startup. Delivery is not forced here; the `app_opened` capture
  /// that follows in main() schedules a flush that carries these along too.
  Future<void> load() => _sink.load();

  /// Records an event. Cheap and synchronous from the caller's view: it
  /// enqueues, mirrors to disk, and schedules a debounced flush.
  void capture(String event, {Map<String, Object?>? properties}) {
    if (!_enabled || !_sink.isConfigured) return;
    _sink.enqueue(PostHogEvent(
      name: event,
      timestamp: _now(),
      properties: {..._superProperties, ...?properties},
    ));
  }

  /// Attribution: link this install's anonymous, device-keyed person to a
  /// stable [userId] (the entitlement token's `sub`) so app + web events unify
  /// into one PostHog person. [setProps] sets person properties. No-ops when
  /// disabled/unconfigured or already identified as [userId].
  void identify(String userId, {Map<String, Object?>? setProps}) {
    if (!_enabled || !_sink.isConfigured) return;
    if (userId.isEmpty || _distinctId == userId) return;
    final anonId = _distinctId;
    _distinctId = userId; // the $identify below (and later events) use the new id
    _sink.setDistinctId(userId);
    _sink.enqueue(PostHogEvent(
      name: r'$identify',
      timestamp: _now(),
      properties: {
        r'$anon_distinct_id': anonId,
        if (setProps != null && setProps.isNotEmpty) r'$set': setProps,
      },
    ));
  }

  /// Delivers everything currently queued in one PostHog /batch/ request. On
  /// failure the queue is left intact for the next attempt.
  ///
  /// Safe to delegate without an `_enabled` check: `setEnabled(false)` clears
  /// the sink queue synchronously, and `capture`/`identify` are
  /// `_enabled`-gated, so a disabled service's sink is always empty.
  Future<void> flush() => _sink.flush();

  /// Toggles capture. Turning it off discards buffered events (opt-out means
  /// "don't send what I did before either"); turning it on starts fresh.
  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) {
      await _sink.clear();
    }
  }

  Future<void> dispose() => _sink.dispose();
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
