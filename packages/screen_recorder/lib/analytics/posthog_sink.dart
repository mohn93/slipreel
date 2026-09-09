import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:slipreel_engine/utils/app_logger.dart';

import 'analytics_event.dart';
import 'analytics_queue_store.dart';

enum DeliveryStatus { sent, queued, unavailable }

/// Bounded, identity-preserving transport shared by usage, diagnostics and
/// explicit feedback. Feedback can distinguish acknowledgement from disk queue.
class PostHogSink {
  PostHogSink({
    required AnalyticsQueueStore store,
    required String distinctId,
    required String projectKey,
    required String host,
    http.Client? client,
    Duration flushDebounce = const Duration(seconds: 5),
    this.maxBytes = 1024 * 1024,
    this.maxBatchEvents = 100,
    this.maxEventBytes = 64 * 1024,
  }) : _store = store,
       _distinctId = distinctId,
       _projectKey = projectKey,
       _host = host,
       _client = client ?? http.Client(),
       _flushDebounce = flushDebounce;

  final AnalyticsQueueStore _store;
  String _distinctId;
  final String _projectKey;
  final String _host;
  final http.Client _client;
  final Duration _flushDebounce;
  final int maxBytes, maxBatchEvents, maxEventBytes;
  final List<PostHogEvent> _queue = [];
  final Map<PostHogEvent, Completer<void>> _receipts = {};
  Future<void>? _flight;
  Future<bool>? _persistence;
  bool _persistAgain = false;
  bool _closing = false;
  bool _disposed = false;
  int _failures = 0;
  Timer? _flushTimer;

  bool get isConfigured => _projectKey.startsWith('phc_');
  int get pendingCount => _queue.length;
  int get pendingBytes => _queue.fold(0, (n, e) => n + _bytes(e));
  Duration get retryDelay => _failures == 0
      ? _flushDebounce
      : Duration(seconds: math.min(300, 5 * (1 << math.min(_failures - 1, 6))));
  int _bytes(PostHogEvent e) => utf8.encode(jsonEncode(e.toJson())).length;

  Future<void> load() async {
    if (!isConfigured || _closing) return;
    // Old queue records have no reliable account owner. Do not assign them
    // to whoever signs in next; discard them during migration.
    for (final event in await _store.load()) {
      if (event.distinctId != null && _bytes(event) <= maxEventBytes) {
        _queue.add(event);
      }
    }
    _trim();
    await _persist();
    if (_queue.isNotEmpty) _scheduleFlush();
  }

  void setDistinctId(String id) => _distinctId = id;

  PostHogEvent? _add(PostHogEvent event) {
    if (!isConfigured || _closing) return null;
    final bound = event.withIdentity(_distinctId);
    if (_bytes(bound) > maxEventBytes || _bytes(bound) > maxBytes) return null;
    _queue.add(bound);
    _trim();
    return _queue.contains(bound) ? bound : null;
  }

  void _trim() {
    var bytes = pendingBytes;
    while (_queue.isNotEmpty &&
        (_queue.length > _store.maxEvents || bytes > maxBytes)) {
      bytes -= _bytes(_queue.removeAt(0));
    }
  }

  void enqueue(PostHogEvent event) {
    if (_add(event) == null) return;
    unawaited(_persist());
    _scheduleFlush();
  }

  /// Resolves only after disk persistence and a bounded delivery attempt.
  Future<DeliveryStatus> submit(PostHogEvent event) async {
    final bound = _add(event);
    if (bound == null) return DeliveryStatus.unavailable;
    final receipt = Completer<void>();
    _receipts[bound] = receipt;
    try {
      final durable = await _persist();
      await flush();
      if (receipt.isCompleted) return DeliveryStatus.sent;
      if (durable && _queue.contains(bound)) return DeliveryStatus.queued;
      return DeliveryStatus.unavailable;
    } finally {
      _receipts.remove(bound);
    }
  }

  /// Coalesce high-frequency enqueue calls rather than retaining a snapshot
  /// for every slider event while the disk is busy.
  Future<bool> _persist() {
    _persistAgain = true;
    return _persistence ??= _persistLoop().whenComplete(
      () => _persistence = null,
    );
  }

  Future<bool> _persistLoop() async {
    var ok = true;
    while (_persistAgain) {
      _persistAgain = false;
      try {
        await _store.save(List.of(_queue));
        ok = true;
      } catch (_) {
        ok = false;
      }
    }
    return ok;
  }

  void _scheduleFlush() {
    if (_closing || _queue.isEmpty || _flushTimer != null) return;
    _flushTimer = Timer(retryDelay, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    if (_disposed) return Future.value();
    return _flight ??= _flush().whenComplete(() => _flight = null);
  }

  Future<void> _flush() async {
    if (!isConfigured || _queue.isEmpty) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    final sent = _queue.take(maxBatchEvents).toList();
    try {
      final res = await _client
          .post(
            Uri.parse('$_host/batch/'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'api_key': _projectKey,
              'historical_migration': false,
              'batch': sent.map((e) => e.toBatchItem(e.distinctId!)).toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _failures = 0;
        for (final event in sent) {
          _queue.remove(event);
          final receipt = _receipts[event];
          if (receipt != null && !receipt.isCompleted) receipt.complete();
        }
        await _persist();
      } else {
        _failures++;
        AppLogger.platform.w(
          'posthog sink: HTTP ${res.statusCode}; will retry',
        );
      }
    } catch (_) {
      _failures++;
    } finally {
      _scheduleFlush();
    }
  }

  Future<void> clear() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
    _failures = 0;
    await _persist();
  }

  Future<void> dispose() async {
    if (_closing) return;
    _closing = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
    await _persist();
    _disposed = true;
    _client.close();
  }
}
