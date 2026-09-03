import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';
import 'package:screen_recorder/diagnostics/diagnostics_service.dart';
import 'package:screen_recorder/diagnostics/exception_event_builder.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('diag'));
  tearDown(() => dir.deleteSync(recursive: true));

  DiagnosticsService build({required bool enabled, required MockClient client}) {
    final scrubber = PiiScrubber(homeDir: '/Users/alice');
    return DiagnosticsService(
      sink: PostHogSink(
        store: AnalyticsQueueStore(path: p.join(dir.path, 'd.json')),
        distinctId: 'd1',
        projectKey: 'phc_test',
        host: 'https://example.test',
        flushDebounce: Duration.zero,
        client: client,
      ),
      builder: ExceptionEventBuilder(scrubber: scrubber, meta: const {'source': 'app'}),
      breadcrumbs: Breadcrumbs(capacity: 5),
      scrubber: scrubber,
      enabled: enabled,
    );
  }

  test('does not send when disabled', () async {
    var calls = 0;
    final svc = build(enabled: false,
        client: MockClient((_) async { calls++; return http.Response('{}', 200); }));
    svc.captureException(StateError('x'), StackTrace.current);
    await svc.flush();
    expect(calls, 0);
  });

  test('sends a \$exception when enabled', () async {
    String? body;
    final svc = build(enabled: true,
        client: MockClient((req) async {
          body = req.body;
          return http.Response('{}', 200);
        }));
    svc.captureException(StateError('x'), StackTrace.current, handled: false);
    await svc.flush();
    expect(body, isNotNull);
    expect(body, contains(r'$exception'));
  });

  test('collapses identical fingerprints within the dedupe window', () async {
    String? body;
    final svc = build(enabled: true,
        client: MockClient((req) async {
          body = req.body;
          return http.Response('{}', 200);
        }));
    final st = StackTrace.current;
    svc.captureException(StateError('a'), st);
    svc.captureException(StateError('b'), st); // same type + top frame -> collapsed
    await svc.flush();
    final batch = jsonDecode(body!)['batch'] as List;
    expect(batch.length, 1);
  });
}
