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
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('diag'));
  tearDown(() => dir.deleteSync(recursive: true));

  DiagnosticsService build({
    required bool enabled,
    required MockClient client,
    int maxPerSession = 50,
    DateTime Function() now = DateTime.now,
  }) {
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
      maxPerSession: maxPerSession,
      now: now,
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

  test('captureNativeCrash sends a native \$exception when enabled', () async {
    String? body;
    final svc = build(enabled: true,
        client: MockClient((req) async {
          body = req.body;
          return http.Response('{}', 200);
        }));
    svc.captureNativeCrash(
      const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1234')],
        reportFileName: 'x.ips',
      ),
      breadcrumbs: ['event:export_started'],
      sessionId: 'sess-1',
    );
    await svc.flush();
    expect(body, isNotNull);
    final batch = jsonDecode(body!)['batch'] as List;
    final props = (batch.single as Map)['properties'] as Map;
    expect((batch.single as Map)['event'], r'$exception');
    expect(props['exception_platform'], 'native');
    expect(props['session_id'], 'sess-1');
  });

  test('captureNativeCrash sends nothing when diagnostics disabled', () async {
    var calls = 0;
    final svc = build(enabled: false,
        client: MockClient((_) async { calls++; return http.Response('{}', 200); }));
    svc.captureNativeCrash(const NativeCrashReport(
        signal: 'SIGSEGV', faultingBinary: 'ffmpeg', frames: [], reportFileName: 'x.ips'));
    await svc.flush();
    expect(calls, 0);
  });

  // C2: the emitted native event is stamped at CRASH time, not scan time.
  test('captureNativeCrash stamps the event at the crash timestamp', () async {
    String? body;
    // `now` (scan time) is deliberately far from the crash time so a
    // scan-time stamp would be obvious.
    final svc = build(enabled: true,
        now: () => DateTime.utc(2030, 1, 1),
        client: MockClient((req) async {
          body = req.body;
          return http.Response('{}', 200);
        }));
    final crashedAt = DateTime.utc(2026, 9, 1, 12);
    svc.captureNativeCrash(NativeCrashReport(
      signal: 'SIGSEGV',
      faultingBinary: 'ffmpeg',
      frames: const [NativeFrame(binary: 'ffmpeg', offset: '0x1')],
      reportFileName: 'x.ips',
      crashedAt: crashedAt,
    ));
    await svc.flush();
    final batch = jsonDecode(body!)['batch'] as List;
    expect((batch.single as Map)['timestamp'], crashedAt.toIso8601String());
  });

  // T1: dedupe — two reports that fingerprint identically within the window
  // send only one event.
  test('captureNativeCrash collapses identical fingerprints within the window',
      () async {
    String? body;
    final svc = build(enabled: true,
        client: MockClient((req) async {
          body = req.body;
          return http.Response('{}', 200);
        }));
    NativeCrashReport r() => const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1234')],
        reportFileName: 'x.ips');
    svc.captureNativeCrash(r());
    svc.captureNativeCrash(r()); // same fingerprint -> collapsed
    await svc.flush();
    final batch = jsonDecode(body!)['batch'] as List;
    expect(batch.length, 1);
  });

  // T1: a native crash is dropped once maxPerSession is hit (shared counter).
  test('captureNativeCrash stops sending after maxPerSession is reached',
      () async {
    var batchItems = 0;
    final svc = build(enabled: true,
        maxPerSession: 1,
        client: MockClient((req) async {
          batchItems += (jsonDecode(req.body)['batch'] as List).length;
          return http.Response('{}', 200);
        }));
    // First distinct crash is sent; a second distinct crash exceeds the cap.
    svc.captureNativeCrash(const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1')],
        reportFileName: 'a.ips'));
    svc.captureNativeCrash(const NativeCrashReport(
        signal: 'SIGABRT',
        faultingBinary: 'whisper-cli',
        frames: [NativeFrame(binary: 'whisper-cli', offset: '0x2')],
        reportFileName: 'b.ips'));
    await svc.flush();
    expect(batchItems, 1);
  });
}
