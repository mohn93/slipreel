import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/analytics_service.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';

class MemoryStore extends AnalyticsQueueStore {
  MemoryStore(): super(path: '/unused', maxEvents: 500);
  @override Future<void> save(List<AnalyticsEvent> events) async {}
  @override Future<void> clear() async {}
}
void main() {
  test('audit: queued activity from A is relabeled as B after switching accounts', () async {
    final batches = <List<dynamic>>[];
    final service = AnalyticsService(store: MemoryStore(), distinctId: 'device_hash', enabled: true,
      projectKey: 'phc_test', host: 'https://example.test', flushDebounce: const Duration(days: 1),
      client: MockClient((req) async { batches.add(jsonDecode(req.body)['batch']); return http.Response('{}', 200); }));
    service.identify('user_A');
    await service.flush();
    service.capture('activity_under_A');
    service.identify('user_B');
    await service.flush();
    expect(batches.last.first['event'], 'activity_under_A');
    expect(batches.last.first['distinct_id'], 'user_B');
    expect(batches.last.last['properties'][r'$anon_distinct_id'], 'user_A');
    await service.setEnabled(false); await service.dispose();
  });
  test('audit: in-memory queue exceeds the persistent store cap', () async {
    final sink = PostHogSink(store: MemoryStore(), distinctId: 'device_hash', projectKey: 'phc_test',
      host: 'https://example.test', flushDebounce: const Duration(days: 1),
      client: MockClient((_) async => http.Response('{}', 200)));
    for(var i = 0; i < 1001; i++) { sink.enqueue(PostHogEvent(name: 'event', timestamp: DateTime.now())); }
    expect(sink.pendingCount, 1001);
    await sink.clear(); await sink.dispose();
  });
}
