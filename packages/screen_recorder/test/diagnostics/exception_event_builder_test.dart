import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/exception_event_builder.dart';
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  final builder = ExceptionEventBuilder(
    scrubber: PiiScrubber(homeDir: '/Users/alice'),
    meta: {'source': 'app', 'platform': 'macos', 'app_version': '1.0.0+1'},
  );

  test('builds a \$exception event with the PostHog list shape', () {
    final e = builder.fromDart(
      RangeError('index /Users/alice/x out of range'),
      StackTrace.current,
      handled: false,
      breadcrumbs: ['[UI] INFO opened'],
    );
    expect(e.name, r'$exception');
    final list = e.properties[r'$exception_list'] as List;
    final item = list.single as Map<String, Object?>;
    expect(item['type'], 'RangeError');
    expect((item['mechanism'] as Map)['handled'], false);
    expect((item['mechanism'] as Map)['synthetic'], false);
    final frames = (item['stacktrace'] as Map)['frames'] as List;
    expect(frames, isNotEmpty);
    // PostHog requires platform + lang on every frame for ingestion/grouping.
    final frame = frames.first as Map;
    expect(frame['platform'], 'custom');
    expect(frame['lang'], 'dart');
    expect(frame['resolved'], true);
  });

  test('redacts a file path out of the exception message', () {
    final e = builder.fromDart(
      StateError('/Users/alice/secret.mov failed'), null, handled: true);
    final item = (e.properties[r'$exception_list'] as List).single as Map;
    expect(item['value'], isNot(contains('/Users/alice')));
    expect(item['value'], isNot(contains('secret.mov')));
    // Non-path context around the path survives.
    expect(item['value'], contains('failed'));
  });

  test('attaches meta and breadcrumbs and a fingerprint', () {
    final e = builder.fromDart(ArgumentError('bad'), null, handled: true,
        breadcrumbs: ['[UI] INFO a']);
    expect(e.properties['source'], 'app');
    expect(e.properties['app_version'], '1.0.0+1');
    expect(e.properties['breadcrumbs'], ['[UI] INFO a']);
    expect(e.properties[r'$exception_fingerprint'], isNotEmpty);
  });

  test('parses VM frames into function/filename/lineno/colno', () {
    final stack = StackTrace.fromString(
      '#0      Foo.bar.<anonymous closure> (package:screen_recorder/x.dart:12:3)\n'
      '#1      _rootRun (dart:async/zone.dart:1391:47)\n'
      '#2      NoColumn.method (package:screen_recorder/y.dart:5)\n'
      '<asynchronous suspension>',
    );
    final e = builder.fromDart(StateError('x'), stack, handled: false);
    final frames =
        ((e.properties[r'$exception_list'] as List).single
            as Map)['stacktrace'] as Map;
    final f = (frames['frames'] as List).cast<Map>();

    expect(f[0]['function'], 'Foo.bar.<anonymous closure>');
    expect(f[0]['filename'], 'package:screen_recorder/x.dart');
    expect(f[0]['lineno'], 12);
    expect(f[0]['colno'], 3);
    expect(f[0]['in_app'], true);
    // Every frame still carries the PostHog-required fields.
    expect(f[0]['platform'], 'custom');
    expect(f[0]['lang'], 'dart');

    // dart: frame is not in-app.
    expect(f[1]['filename'], 'dart:async/zone.dart');
    expect(f[1]['lineno'], 1391);
    expect(f[1]['in_app'], false);

    // line without a column: lineno set, colno absent.
    expect(f[2]['lineno'], 5);
    expect(f[2].containsKey('colno'), false);

    // Unparseable line (async gap) falls back to the whole line as function.
    expect(f[3]['function'], contains('asynchronous suspension'));
    expect(f[3].containsKey('filename'), false);
  });

  test('fingerprint is stable for the same error type + top frame', () {
    final st = StackTrace.current;
    expect(builder.fingerprintFor(ArgumentError('x'), st),
        builder.fingerprintFor(ArgumentError('y'), st));
  });

  test('messageOverride redacts the raw error message', () {
    final e = builder.fromDart(
      StateError('/Users/alice/secret.mov failed'),
      null,
      handled: true,
      messageOverride: 'StateError',
    );
    final item = (e.properties[r'$exception_list'] as List).single as Map;
    expect(item['value'], 'StateError');
    expect(item['value'], isNot(contains('secret.mov')));
  });

  test('redacts file paths in context string values', () {
    final e = builder.fromDart(StateError('x'), null, handled: true,
        context: {'path': '/Users/alice/secret.mov', 'count': 3});
    final ctx = e.properties['context'] as Map;
    expect(ctx['path'], isNot(contains('/Users/alice')));
    expect(ctx['path'], isNot(contains('secret.mov')));
    expect(ctx['count'], 3); // non-strings untouched
  });

  test('recursively redacts paths nested in context maps/lists', () {
    final e = builder.fromDart(StateError('x'), null, handled: true, context: {
      'nested': {'p': '/Users/alice/deep.mov'},
      'items': ['/Users/alice/a.mov', 'plain'],
    });
    final ctx = e.properties['context'] as Map;
    expect((ctx['nested'] as Map)['p'], isNot(contains('deep.mov')));
    final items = (ctx['items'] as List).cast<String>();
    expect(items[0], isNot(contains('a.mov')));
    expect(items[1], 'plain');
  });

  test('fromNative builds a native \$exception with v1a mechanism shape', () {
    final report = NativeCrashReport(
      signal: 'SIGSEGV',
      faultingBinary: 'ffmpeg',
      frames: const [
        NativeFrame(binary: 'ffmpeg', offset: '0x1234'),
        NativeFrame(binary: 'libsystem.dylib', offset: '0x1'),
      ],
      reportFileName: 'x.ips',
      osVersion: 'macOS 15.5',
    );
    final e = builder.fromNative(report,
        breadcrumbs: ['event:export_started'],
        activity: {'op': 'export'},
        sessionId: 'sess-1');
    expect(e.name, r'$exception');
    expect(e.properties['exception_platform'], 'native');
    expect(e.properties['session_id'], 'sess-1');
    expect(e.properties['breadcrumbs'], ['event:export_started']);
    expect((e.properties['context'] as Map)['op'], 'export');
    final item = (e.properties[r'$exception_list'] as List).single as Map;
    expect(item['type'], 'SIGSEGV');
    expect(item['mechanism'], {'handled': false, 'synthetic': false});
    final frames = (item['stacktrace'] as Map)['frames'] as List;
    final f0 = frames.first as Map;
    expect(f0['platform'], 'custom');
    expect(f0['lang'], 'native');
    expect(f0['resolved'], false);
    expect(f0['function'], 'ffmpeg');
    expect(f0['instruction_addr'], contains('0x1234'));
  });

  test('fromNative fingerprint is stable for same signal+binary+top offset', () {
    NativeCrashReport r() => const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1234')],
        reportFileName: 'a.ips');
    expect(builder.fromNative(r()).properties[r'$exception_fingerprint'],
        builder.fromNative(r()).properties[r'$exception_fingerprint']);
    expect(builder.fromNative(r()).properties[r'$exception_fingerprint'],
        'SIGSEGV|ffmpeg|0x1234');
  });

  test(
      'fromNative never inherits the current launch\'s session_id from meta',
      () {
    final builderWithCurrentSession = ExceptionEventBuilder(
      scrubber: PiiScrubber(homeDir: '/Users/alice'),
      meta: {'source': 'app', 'session_id': 'current-launch'},
    );
    const report = NativeCrashReport(
      signal: 'SIGSEGV',
      faultingBinary: 'ffmpeg',
      frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1234')],
      reportFileName: 'a.ips',
    );

    // Subprocess-crash case: the crashed session's id is unknown (its
    // session.json was deleted on clean exit). Must NOT fall back to the
    // current scanning launch's session_id.
    final noSession =
        builderWithCurrentSession.fromNative(report, sessionId: null);
    expect(noSession.properties.containsKey('session_id'), false);

    // In-process-crash case: the crashed session's own id is known and used.
    final withSession =
        builderWithCurrentSession.fromNative(report, sessionId: 'crashed');
    expect(withSession.properties['session_id'], 'crashed');
  });

  test('fromNative omits context when no activity', () {
    final e = builder.fromNative(const NativeCrashReport(
        signal: 'SIGABRT',
        faultingBinary: 'whisper-cli',
        frames: [],
        reportFileName: 'a.ips'));
    expect(e.properties.containsKey('context'), false);
  });

  // I5: genuine in-process (app) frames must be marked in_app.
  test('a native frame in the app binary is in_app: true', () {
    final e = builder.fromNative(const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'Slipreel',
        frames: [NativeFrame(binary: 'Slipreel', offset: '0x1')],
        reportFileName: 'a.ips'));
    final st = ((e.properties[r'$exception_list'] as List).single
        as Map)['stacktrace'] as Map;
    expect((st['frames'] as List).first['in_app'], true);
  });

  // I4: the crashed app version is forwarded distinctly and never overwrites
  // the current launch's app_version (which comes from meta).
  test('fromNative forwards the crashed app version distinctly from app_version',
      () {
    final e = builder.fromNative(const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1')],
        reportFileName: 'a.ips',
        appVersion: '0.9.0+3'));
    expect(e.properties['crashed_app_version'], '0.9.0+3');
    // The current launch's app_version (from meta) is untouched.
    expect(e.properties['app_version'], '1.0.0+1');
  });

  test('fromNative omits crashed_app_version when the report has none', () {
    final e = builder.fromNative(const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1')],
        reportFileName: 'a.ips'));
    expect(e.properties.containsKey('crashed_app_version'), false);
  });

  // I6: fingerprint by the first in-app frame so distinct bugs that share a
  // generic top frame (libc abort/__pthread_kill) don't collapse into one.
  test(
      'fromNative fingerprints by the first in-app frame, not the generic top',
      () {
    NativeCrashReport withInApp(String offset) => NativeCrashReport(
          signal: 'SIGABRT',
          faultingBinary: 'Slipreel',
          frames: [
            const NativeFrame(binary: 'libsystem_kernel.dylib', offset: '0x1'),
            const NativeFrame(binary: 'libsystem_c.dylib', offset: '0x2'),
            NativeFrame(binary: 'Slipreel', offset: offset),
          ],
          reportFileName: 'a.ips',
        );
    final a =
        builder.fromNative(withInApp('0xaaa')).properties[r'$exception_fingerprint'];
    final b =
        builder.fromNative(withInApp('0xbbb')).properties[r'$exception_fingerprint'];
    // Same signal + faulting binary + generic top frame, but different bugs.
    expect(a, isNot(b));
    // The chosen offset is the first in-app frame's, not the libc top frame's.
    expect(a, 'SIGABRT|Slipreel|0xaaa');
  });

  test(
      'fromNative fingerprint falls back to the top frame when no in-app frame '
      'exists, and is stable for the same crash', () {
    NativeCrashReport r() => const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'Google Chrome',
        frames: [NativeFrame(binary: 'libsystem.dylib', offset: '0x9')],
        reportFileName: 'a.ips');
    expect(builder.fromNative(r()).properties[r'$exception_fingerprint'],
        builder.fromNative(r()).properties[r'$exception_fingerprint']);
    expect(builder.fromNative(r()).properties[r'$exception_fingerprint'],
        'SIGSEGV|Google Chrome|0x9');
  });
}
