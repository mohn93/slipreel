import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slipreel_engine/utils/app_logger.dart';

import 'analytics_event.dart';
import 'analytics_queue_store.dart';

/// Policy-free PostHog `/batch/` transport: buffers events in memory, mirrors
/// them to a bounded on-disk queue, and delivers them best-effort. Gating
/// (opt-out, event category) is the caller's concern; this only refuses to
/// send when no real project key was baked in.
class PostHogSink {
  PostHogSink({
    required AnalyticsQueueStore store,
    required String distinctId,
    required String projectKey,
    required String host,
    http.Client? client,
    Duration flushDebounce = const Duration(seconds: 5),
    DateTime Function() now = DateTime.now,
  })  : _store = store,
        _distinctId = distinctId,
        _projectKey = projectKey,
        _host = host,
        _client = client ?? http.Client(),
        _flushDebounce = flushDebounce,
        _now = now;

  final AnalyticsQueueStore _store;
  String _distinctId;
  final String _projectKey;
  final String _host;
  final http.Client _client;
  final Duration _flushDebounce;
  final DateTime Function() _now;

  final List<PostHogEvent> _queue = [];
  bool _flushing = false;
  Timer? _flushTimer;

  bool get isConfigured => _projectKey.startsWith('phc_');
  int get pendingCount => _queue.length;

  Future<void> load() async {
    if (!isConfigured) return;
    _queue.addAll(await _store.load());
  }

  void setDistinctId(String id) => _distinctId = id;

  void enqueue(PostHogEvent event) {
    if (!isConfigured) return;
    _queue.add(event);
    unawaited(_store.save(_queue));
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDebounce, () => unawaited(flush()));
  }

  Future<void> flush() async {
    if (_flushing || !isConfigured || _queue.isEmpty) return;
    _flushing = true;
    _flushTimer?.cancel();
    final sent = List<PostHogEvent>.of(_queue);
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
        final delivered = Set<PostHogEvent>.identity()..addAll(sent);
        _queue.removeWhere(delivered.contains);
        await _store.save(_queue);
      } else {
        AppLogger.platform.w('posthog sink: HTTP ${res.statusCode}; will retry');
      }
    } catch (e) {
      AppLogger.platform.d('posthog sink flush deferred: $e');
    } finally {
      _flushing = false;
      if (_queue.isNotEmpty) _scheduleFlush();
    }
  }

  Future<void> clear() async {
    _flushTimer?.cancel();
    _queue.clear();
    await _store.clear();
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flush();
    _client.close();
  }
}
