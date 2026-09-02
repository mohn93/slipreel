import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/analytics_service.dart';

void main() {
  late Directory dir;
  late AnalyticsQueueStore store;
  final created = <AnalyticsService>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('analytics_test');
    store = AnalyticsQueueStore(path: '${dir.path}/queue.json');
  });
  tearDown(() async {
    // Dispose to cancel any pending debounce timer (else it leaks past the
    // test under parallel runs); a disabled/disposed service's flush no-ops.
    for (final a in created) {
      await a.setEnabled(false);
      await a.dispose();
    }
    created.clear();
    // capture() mirrors to disk fire-and-forget; let any in-flight write settle
    // before removing the dir, and tolerate the reap racing a late write.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      /* best-effort; the OS reaps the temp dir anyway */
    }
  });

  AnalyticsService svc({
    required http.Client client,
    bool enabled = true,
    String projectKey = 'phc_test',
    Map<String, Object?> superProps = const {'source': 'app'},
  }) {
    final a = AnalyticsService(
      store: store,
      distinctId: 'device_hash',
      enabled: enabled,
      client: client,
      projectKey: projectKey,
      host: 'https://ph.example.test',
      superProperties: superProps,
      // Long, so the debounce timer never fires mid-test; tests drive
      // delivery explicitly via flush().
      flushDebounce: const Duration(seconds: 30),
    );
    created.add(a);
    return a;
  }

  test('capture + flush posts /batch/ with api_key, distinct_id, merged props',
      () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response('{"status":1}', 200);
    });
    final a = svc(client: client);
    a.capture('recording_started', properties: {'foo': 1});
    await a.flush();

    expect(seen, isNotNull);
    expect(seen!.url.toString(), 'https://ph.example.test/batch/');
    expect(seen!.method, 'POST');
    final body = jsonDecode(seen!.body) as Map<String, dynamic>;
    expect(body['api_key'], 'phc_test');
    final batch = body['batch'] as List;
    expect(batch, hasLength(1));
    final item = batch.first as Map<String, dynamic>;
    expect(item['event'], 'recording_started');
    expect(item['distinct_id'], 'device_hash');
    final props = item['properties'] as Map<String, dynamic>;
    expect(props['foo'], 1);
    expect(props['source'], 'app'); // super property merged in
    expect(item['timestamp'], isA<String>());
  });

  test('successful flush clears the queue; a second flush sends nothing',
      () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });
    final a = svc(client: client);
    a.capture('e1');
    await a.flush();
    await a.flush();
    expect(calls, 1);
  });

  test('failed flush keeps the queue; the next flush re-sends it', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return calls == 1
          ? http.Response('boom', 500)
          : http.Response('{}', 200);
    });
    final a = svc(client: client);
    a.capture('e1');
    await a.flush(); // 500 -> kept
    await a.flush(); // 200 -> delivered
    await a.flush(); // nothing left
    expect(calls, 2);
  });

  test('opt-out discards buffered events and stops sending', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });
    final a = svc(client: client);
    a.capture('e1');
    await a.setEnabled(false);
    a.capture('e2');
    await a.flush();
    expect(calls, 0);
    expect(a.enabled, isFalse);
    expect(await store.load(), isEmpty);
  });

  test('disabled service never flushes a stale on-disk queue', () async {
    await store.save([
      AnalyticsEvent(name: 'stale', timestamp: DateTime.now()),
    ]);
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });
    final a = svc(client: client, enabled: false);
    await a.load();
    await a.flush();
    expect(calls, 0);
  });

  test('no-op when unconfigured (empty project key)', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });
    final a = svc(client: client, projectKey: '');
    a.capture('e1');
    await a.flush();
    expect(calls, 0);
  });

  test('load() re-sends events left over from a previous run', () async {
    await store.save([
      AnalyticsEvent(
        name: 'leftover',
        timestamp: DateTime.utc(2026, 1, 1),
        properties: const {'k': 'v'},
      ),
    ]);
    http.Request? seen;
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      seen = req;
      return http.Response('{}', 200);
    });
    final a = svc(client: client);
    await a.load();
    await a.flush();
    expect(calls, 1);
    final batch = (jsonDecode(seen!.body) as Map<String, dynamic>)['batch'] as List;
    expect((batch.first as Map<String, dynamic>)['event'], 'leftover');
  });

  test(r'identify emits $identify (anon->user + $set) and switches distinct_id',
      () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response('{}', 200);
    });
    final a = svc(client: client);
    a.identify('user_42', setProps: {'email': 'u@e.com'});
    a.capture('after_identify');
    await a.flush();

    final batch =
        (jsonDecode(seen!.body) as Map<String, dynamic>)['batch'] as List;
    final idEvent = batch.firstWhere((e) => e['event'] == r'$identify')
        as Map<String, dynamic>;
    expect(idEvent['distinct_id'], 'user_42');
    final props = idEvent['properties'] as Map<String, dynamic>;
    expect(props[r'$anon_distinct_id'], 'device_hash');
    expect((props[r'$set'] as Map)['email'], 'u@e.com');
    // Events after identify carry the identified id.
    final after = batch.firstWhere((e) => e['event'] == 'after_identify')
        as Map<String, dynamic>;
    expect(after['distinct_id'], 'user_42');
  });

  test(r'identify twice to the same id emits only one $identify', () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response('{}', 200);
    });
    final a = svc(client: client);
    a.identify('user_1');
    a.identify('user_1');
    await a.flush();
    final batch =
        (jsonDecode(seen!.body) as Map<String, dynamic>)['batch'] as List;
    expect(batch.where((e) => e['event'] == r'$identify').length, 1);
  });

  test('identify no-ops when disabled', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('{}', 200);
    });
    final a = svc(client: client, enabled: false);
    a.identify('user_1');
    await a.flush();
    expect(calls, 0);
  });
}
