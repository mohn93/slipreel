import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';
import 'package:screen_recorder/feedback/feedback_service.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('fb'));
  tearDown(() => dir.deleteSync(recursive: true));

  FeedbackService build(MockClient client) => FeedbackService(
        sink: PostHogSink(
          store: AnalyticsQueueStore(path: p.join(dir.path, 'f.json')),
          distinctId: 'd1',
          projectKey: 'phc_test',
          host: 'https://example.test',
          flushDebounce: Duration.zero,
          client: client,
        ),
        breadcrumbs: Breadcrumbs(capacity: 5),
        scrubber: PiiScrubber(homeDir: '/Users/alice'),
        meta: const {'source': 'app', 'app_version': '1.0.0+1'},
      );

  test('submits a feedback_submitted event with type + message', () async {
    Map<String, dynamic>? item;
    final svc = build(MockClient((req) async {
      item = (jsonDecode(req.body)['batch'] as List).single as Map<String, dynamic>;
      return http.Response('{}', 200);
    }));
    await svc.submit(const FeedbackReport(type: FeedbackType.problem, message: 'broke'));
    expect(item!['event'], 'feedback_submitted');
    final props = item!['properties'] as Map<String, dynamic>;
    expect(props['type'], 'problem');
    expect(props['message'], 'broke');
    expect(props.containsKey('breadcrumbs'), isFalse); // not attached
  });

  test('attaches diagnostics only when requested', () async {
    Map<String, dynamic>? props;
    final svc = build(MockClient((req) async {
      final item = (jsonDecode(req.body)['batch'] as List).single as Map<String, dynamic>;
      props = item['properties'] as Map<String, dynamic>;
      return http.Response('{}', 200);
    }));
    await svc.submit(const FeedbackReport(
        type: FeedbackType.idea, message: 'nice', email: 'a@b.co', attachDiagnostics: true));
    expect(props!['email'], 'a@b.co');
    expect(props!.containsKey('breadcrumbs'), isTrue);
    expect(props!['app_version'], '1.0.0+1');
  });
}
