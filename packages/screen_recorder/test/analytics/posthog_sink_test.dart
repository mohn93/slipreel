import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sink'));
  tearDown(() => dir.deleteSync(recursive: true));

  AnalyticsQueueStore store() =>
      AnalyticsQueueStore(path: p.join(dir.path, 'q.json'));

  test('no-ops entirely when unconfigured (no phc_ key)', () async {
    var calls = 0;
    final sink = PostHogSink(
      store: store(),
      distinctId: 'd1',
      projectKey: '',
      host: 'https://example.test',
      client: MockClient((_) async { calls++; return http.Response('', 200); }),
    );
    sink.enqueue(PostHogEvent(name: 'x', timestamp: DateTime.now()));
    await sink.flush();
    expect(sink.isConfigured, isFalse);
    expect(calls, 0);
  });

  test('posts queued events to /batch/ and clears on 2xx', () async {
    Map<String, dynamic>? body;
    final sink = PostHogSink(
      store: store(),
      distinctId: 'd1',
      projectKey: 'phc_test',
      host: 'https://example.test',
      flushDebounce: Duration.zero,
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"status":1}', 200);
      }),
    );
    sink.enqueue(PostHogEvent(name: 'evt', timestamp: DateTime.now()));
    await sink.flush();
    expect(body!['api_key'], 'phc_test');
    expect((body!['batch'] as List).single['distinct_id'], 'd1');
    expect(sink.pendingCount, 0);
  });

  test('keeps queue on non-2xx for retry', () async {
    final sink = PostHogSink(
      store: store(),
      distinctId: 'd1',
      projectKey: 'phc_test',
      host: 'https://example.test',
      flushDebounce: Duration.zero,
      client: MockClient((_) async => http.Response('nope', 500)),
    );
    sink.enqueue(PostHogEvent(name: 'evt', timestamp: DateTime.now()));
    await sink.flush();
    expect(sink.pendingCount, 1);
  });

  test('setDistinctId changes the id used at send time', () async {
    Map<String, dynamic>? body;
    final sink = PostHogSink(
      store: store(),
      distinctId: 'anon',
      projectKey: 'phc_test',
      host: 'https://example.test',
      flushDebounce: Duration.zero,
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      }),
    );
    sink.setDistinctId('user-123');
    sink.enqueue(PostHogEvent(name: 'evt', timestamp: DateTime.now()));
    await sink.flush();
    expect((body!['batch'] as List).single['distinct_id'], 'user-123');
  });
}
