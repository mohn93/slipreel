import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';
import 'package:screen_recorder/diagnostics/persistent_crumb_store.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  late Directory dir;
  late String path;
  final scrubber = PiiScrubber(homeDir: '/Users/alice');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crumbstore');
    path = '${dir.path}/session.json';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  PersistentCrumbStore make(Breadcrumbs b, {bool enabled = true}) =>
      PersistentCrumbStore(
          path: path,
          sessionId: 'sess-1',
          breadcrumbs: b,
          scrubber: scrubber,
          enabled: enabled);

  test('writes crumbs + activity, scrubbed', () {
    final b = Breadcrumbs()..dropEvent('export_started');
    final store = make(b)..setActivity({'op': 'export', 'path': '/Users/alice/x.mov'});
    store.writeIfDirty();
    final json = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(json['session_id'], 'sess-1');
    expect((json['breadcrumbs'] as List), contains('event:export_started'));
    expect((json['activity'] as Map)['op'], 'export');
    expect(jsonEncode(json), isNot(contains('/Users/alice')));
  });

  test('writeIfDirty is a no-op when nothing changed since last write, '
      'even after real time passes', () {
    // Regression guard: `launched_at` must be fixed at construction, not
    // recomputed per serialize — otherwise the dirty check (which diffs the
    // full payload) would see a changing timestamp and write every time,
    // even with identical crumbs/activity.
    var current = DateTime(2026, 1, 1);
    final b = Breadcrumbs()..dropEvent('a');
    final store = PersistentCrumbStore(
        path: path,
        sessionId: 'sess-1',
        breadcrumbs: b,
        scrubber: scrubber,
        enabled: true,
        now: () => current);
    store.writeIfDirty();
    final mtime1 = File(path).lastModifiedSync();
    final written1 = File(path).readAsStringSync();
    current = current.add(const Duration(minutes: 5));
    store.writeIfDirty(); // nothing about the session changed
    expect(File(path).lastModifiedSync(), mtime1);
    expect(File(path).readAsStringSync(), written1);
  });

  test('writeIfDirty writes again once crumbs actually change, '
      'after real time passes', () {
    var current = DateTime(2026, 1, 1);
    final b = Breadcrumbs()..dropEvent('a');
    final store = PersistentCrumbStore(
        path: path,
        sessionId: 'sess-1',
        breadcrumbs: b,
        scrubber: scrubber,
        enabled: true,
        now: () => current);
    store.writeIfDirty();
    current = current.add(const Duration(minutes: 5));
    b.dropEvent('b');
    store.writeIfDirty();
    final json = jsonDecode(File(path).readAsStringSync()) as Map;
    expect((json['breadcrumbs'] as List), contains('event:b'));
  });

  test('readPrevious returns the file a prior session left', () {
    File(path).writeAsStringSync(jsonEncode({
      'session_id': 'old',
      'launched_at': '2026-09-01T00:00:00Z',
      'breadcrumbs': ['event:recording_started'],
      'activity': {'op': 'record'},
    }));
    final prev = make(Breadcrumbs()).readPrevious()!;
    expect(prev.sessionId, 'old');
    expect(prev.breadcrumbs, ['event:recording_started']);
    expect(prev.activity!['op'], 'record');
  });

  test('readPrevious returns null for syntactically-valid but wrong-typed '
      'session.json, without throwing', () {
    // 'breadcrumbs' has non-string elements (exercises eager materialization
    // instead of a lazy .cast that would only throw when later iterated),
    // and 'activity' is not an object at all (exercises the Map cast).
    File(path).writeAsStringSync(jsonEncode({
      'session_id': 'sess-old',
      'breadcrumbs': [1, 2, 3],
      'activity': 'not-an-object',
    }));
    PersistedSession? prev;
    expect(() => prev = make(Breadcrumbs()).readPrevious(), returnsNormally);
    expect(prev, isNull);
  });

  test('clearOnCleanExit deletes the file', () {
    final store = make(Breadcrumbs()..dropEvent('a'))..writeIfDirty();
    expect(File(path).existsSync(), true);
    store.clearOnCleanExit();
    expect(File(path).existsSync(), false);
  });

  test('disabled store never writes and clears any existing file', () {
    File(path).writeAsStringSync('{}');
    final store = make(Breadcrumbs()..dropEvent('a'), enabled: false)
      ..setActivity({'op': 'x'});
    store.writeIfDirty();
    store.flushNow();
    expect(store.readPrevious(), isNull);
    store.clearOnCleanExit();
    expect(File(path).existsSync(), false);
  });
}
