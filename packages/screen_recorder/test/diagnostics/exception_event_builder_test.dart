import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
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
    expect((item['mechanism'] as Map)['type'], 'flutter');
    expect(item['stacktrace'], isNotNull);
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
