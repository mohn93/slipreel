import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/exception_event_builder.dart';
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
}
