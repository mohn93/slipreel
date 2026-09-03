import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';
import 'package:screen_recorder/diagnostics/exception_event_builder.dart';
import 'package:screen_recorder/diagnostics/native_crash_scanner.dart';
import 'package:screen_recorder/diagnostics/persistent_crumb_store.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  late Directory reports;
  late Directory state;
  final scrubber = PiiScrubber(homeDir: '/Users/alice');
  final builder = ExceptionEventBuilder(scrubber: scrubber, meta: const {'source': 'app'});

  setUp(() {
    reports = Directory.systemTemp.createTempSync('reports');
    state = Directory.systemTemp.createTempSync('state');
  });
  tearDown(() {
    reports.deleteSync(recursive: true);
    state.deleteSync(recursive: true);
  });

  void writeOurReport() => File('${reports.path}/ours.ips').writeAsStringSync(
        '{"app_name":"Slipreel","timestamp":"2026-09-01 12:00:00.00 +0000","os_version":"macOS 15.5"}\n'
        '{"procName":"ffmpeg","exception":{"signal":"SIGSEGV"},'
        '"usedImages":[{"index":0,"name":"ffmpeg"}],'
        '"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":10}]}]}',
      );

  test('survived session.json attaches crumbs to the native event', () {
    File('${state.path}/session.json').writeAsStringSync(jsonEncode({
      'session_id': 'crashed',
      'breadcrumbs': ['event:export_started'],
      'activity': {'op': 'export'},
    }));
    writeOurReport();

    final store = PersistentCrumbStore(
        path: '${state.path}/session.json',
        sessionId: 'current',
        breadcrumbs: Breadcrumbs(),
        scrubber: scrubber,
        enabled: true);
    final prev = store.readPrevious(); // survived => not null

    final events = [];
    NativeCrashScanner(
      reportsDir: reports,
      watermarkStore: NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
      scrubber: scrubber,
      onCrash: (r) => events.add(builder.fromNative(r,
          breadcrumbs: prev?.breadcrumbs ?? const [],
          activity: prev?.activity,
          sessionId: prev?.sessionId)),
    ).scan();

    expect(events.single.properties['breadcrumbs'], ['event:export_started']);
    expect(events.single.properties['session_id'], 'crashed');
  });

  test('cleared session.json means the native event carries no crumbs', () {
    writeOurReport(); // no session.json => clean prior exit
    final store = PersistentCrumbStore(
        path: '${state.path}/session.json',
        sessionId: 'current',
        breadcrumbs: Breadcrumbs(),
        scrubber: scrubber,
        enabled: true);
    final prev = store.readPrevious(); // null

    final events = [];
    NativeCrashScanner(
      reportsDir: reports,
      watermarkStore: NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
      scrubber: scrubber,
      onCrash: (r) => events.add(builder.fromNative(r,
          breadcrumbs: prev?.breadcrumbs ?? const [],
          activity: prev?.activity,
          sessionId: prev?.sessionId)),
    ).scan();

    expect(events.single.properties['breadcrumbs'], isEmpty);
    expect(events.single.properties.containsKey('context'), false);
  });

  // C1: a surviving session.json must NOT lend its trail to a backlog crash
  // that happened before the session launched.
  test(
      'a backlog crash (older than the session launch) gets no crumbs even '
      'though session.json survived', () {
    // Session launched 2026-09-02; the report below crashed 2026-09-01.
    File('${state.path}/session.json').writeAsStringSync(jsonEncode({
      'session_id': 'crashed',
      'launched_at': '2026-09-02T00:00:00Z',
      'breadcrumbs': ['event:export_started'],
      'activity': {'op': 'export'},
    }));
    writeOurReport(); // report timestamp is 2026-09-01 12:00 (before launch)

    final store = PersistentCrumbStore(
        path: '${state.path}/session.json',
        sessionId: 'current',
        breadcrumbs: Breadcrumbs(),
        scrubber: scrubber,
        enabled: true);
    final prev = store.readPrevious();

    final events = [];
    NativeCrashScanner(
      reportsDir: reports,
      watermarkStore: NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
      scrubber: scrubber,
      onCrash: (r) {
        final attach = crumbTrailAppliesTo(prev, r);
        events.add(builder.fromNative(r,
            breadcrumbs: attach ? (prev?.breadcrumbs ?? const []) : const [],
            activity: attach ? prev?.activity : null,
            sessionId: attach ? prev?.sessionId : null));
      },
    ).scan();

    expect(events.single.properties['breadcrumbs'], isEmpty);
    expect(events.single.properties.containsKey('session_id'), false);
    expect(events.single.properties.containsKey('context'), false);
  });

  // C1: a crash at/after the session launch DOES inherit the trail.
  test(
      'an in-window crash (at/after the session launch) inherits the crumbs '
      'and session id', () {
    // Session launched 2026-09-01 00:00; report crashed 2026-09-01 12:00.
    File('${state.path}/session.json').writeAsStringSync(jsonEncode({
      'session_id': 'crashed',
      'launched_at': '2026-09-01T00:00:00Z',
      'breadcrumbs': ['event:export_started'],
      'activity': {'op': 'export'},
    }));
    writeOurReport();

    final store = PersistentCrumbStore(
        path: '${state.path}/session.json',
        sessionId: 'current',
        breadcrumbs: Breadcrumbs(),
        scrubber: scrubber,
        enabled: true);
    final prev = store.readPrevious();

    final events = [];
    NativeCrashScanner(
      reportsDir: reports,
      watermarkStore: NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
      scrubber: scrubber,
      onCrash: (r) {
        final attach = crumbTrailAppliesTo(prev, r);
        events.add(builder.fromNative(r,
            breadcrumbs: attach ? (prev?.breadcrumbs ?? const []) : const [],
            activity: attach ? prev?.activity : null,
            sessionId: attach ? prev?.sessionId : null));
      },
    ).scan();

    expect(events.single.properties['breadcrumbs'], ['event:export_started']);
    expect(events.single.properties['session_id'], 'crashed');
    expect((events.single.properties['context'] as Map)['op'], 'export');
  });
}
