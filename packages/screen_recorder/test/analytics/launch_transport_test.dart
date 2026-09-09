import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/analytics_service.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('launch-transport');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  AnalyticsQueueStore store({int cap = 500}) =>
      AnalyticsQueueStore(path: '${dir.path}/q.json', maxEvents: cap);
  PostHogEvent event(String name) =>
      PostHogEvent(name: name, timestamp: DateTime.utc(2026));

  test(
    'account switch preserves queued identities including after restart',
    () async {
      final first = PostHogSink(
        store: store(),
        distinctId: 'A',
        projectKey: 'phc_test',
        host: 'https://example.test',
        flushDebounce: const Duration(days: 1),
        client: MockClient((_) async => http.Response('', 503)),
      );
      first.enqueue(event('A-feedback'));
      first.setDistinctId('B');
      first.enqueue(event('B-feedback'));
      await first.dispose();
      List<dynamic>? delivered;
      final next = PostHogSink(
        store: store(),
        distinctId: 'C',
        projectKey: 'phc_test',
        host: 'https://example.test',
        client: MockClient((req) async {
          delivered = jsonDecode(req.body)['batch'];
          return http.Response('', 200);
        }),
      );
      await next.load();
      await next.flush();
      await next.dispose();
      expect(delivered!.map((e) => e['distinct_id']), ['A', 'B']);
    },
  );

  test('account A is never used as anonymous identity for B', () async {
    final delivered = <dynamic>[];
    final service = AnalyticsService(
      store: store(),
      distinctId: 'anon_launch',
      enabled: true,
      projectKey: 'phc_test',
      host: 'https://example.test',
      flushDebounce: const Duration(days: 1),
      client: MockClient((req) async {
        delivered.addAll(jsonDecode(req.body)['batch']);
        return http.Response('', 200);
      }),
    );
    service.identify('A');
    service.capture('under_A');
    service.identify('B');
    service.resetIdentity();
    final anonymous = service.distinctId;
    service.capture('signed_out');
    service.identify('C');
    await service.flush();
    await service.dispose();
    expect(
      delivered.firstWhere((e) => e['event'] == 'under_A')['distinct_id'],
      'A',
    );
    expect(
      delivered.firstWhere((e) => e['event'] == 'signed_out')['distinct_id'],
      anonymous,
    );
    expect(
      delivered
          .where((e) => e['event'] == r'$identify')
          .map((e) => e['properties'][r'$anon_distinct_id']),
      ['anon_launch', anonymous],
    );
  });

  test('queue is bounded and delivery uses bounded batches', () async {
    final batches = <List<dynamic>>[];
    final sink = PostHogSink(
      store: store(cap: 5),
      distinctId: 'A',
      projectKey: 'phc_test',
      host: 'https://example.test',
      maxBatchEvents: 2,
      maxBytes: 4096,
      flushDebounce: const Duration(days: 1),
      client: MockClient((req) async {
        batches.add(jsonDecode(req.body)['batch']);
        return http.Response('', 200);
      }),
    );
    for (var i = 0; i < 20; i++) {
      sink.enqueue(event('event_$i'));
    }
    expect(sink.pendingCount, 5);
    expect(sink.pendingBytes, lessThanOrEqualTo(4096));
    await sink.flush();
    expect(batches.single.length, 2);
    expect(sink.pendingCount, 3);
    await sink.clear();
    await sink.dispose();
  });

  test(
    'failed delivery backs off and dispose never schedules another attempt',
    () async {
      var calls = 0;
      final sink = PostHogSink(
        store: store(),
        distinctId: 'A',
        projectKey: 'phc_test',
        host: 'https://example.test',
        client: MockClient((_) async {
          calls++;
          return http.Response('', 503);
        }),
      );
      sink.enqueue(event('offline'));
      await sink.flush();
      expect(sink.retryDelay, const Duration(seconds: 5));
      await sink.flush();
      expect(sink.retryDelay, const Duration(seconds: 10));
      await sink.dispose();
      final count = calls;
      sink.enqueue(event('closed'));
      await sink.flush();
      expect(calls, count);
    },
  );

  test(
    'feedback is sent only on acknowledgement; offline is durably queued',
    () async {
      var online = false;
      final sink = PostHogSink(
        store: store(),
        distinctId: 'A',
        projectKey: 'phc_test',
        host: 'https://example.test',
        client: MockClient((_) async => http.Response('', online ? 200 : 503)),
      );
      expect(await sink.submit(event('offline')), DeliveryStatus.queued);
      expect((await store().load()).single.distinctId, 'A');
      online = true;
      expect(await sink.submit(event('online')), DeliveryStatus.sent);
      await sink.dispose();
    },
  );

  test(
    'feedback cannot claim queued when disk and network both fail',
    () async {
      final file = File('${dir.path}/not-a-directory');
      await file.writeAsString('x');
      final sink = PostHogSink(
        store: AnalyticsQueueStore(path: '${file.path}/q'),
        distinctId: 'A',
        projectKey: 'phc_test',
        host: 'https://example.test',
        client: MockClient((_) async => http.Response('', 503)),
      );
      expect(await sink.submit(event('failure')), DeliveryStatus.unavailable);
      await sink.dispose();
    },
  );

  test(
    'legacy ownerless events are not reassigned to the current account',
    () async {
      await store().save([event('old')]);
      final sink = PostHogSink(
        store: store(),
        distinctId: 'new_account',
        projectKey: 'phc_test',
        host: 'https://example.test',
      );
      await sink.load();
      expect(sink.pendingCount, 0);
      await sink.dispose();
    },
  );
}
