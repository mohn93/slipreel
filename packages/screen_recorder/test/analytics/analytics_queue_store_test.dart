import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
import 'package:screen_recorder/analytics/analytics_queue_store.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('analytics_queue_test');
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  AnalyticsEvent e(String name) =>
      AnalyticsEvent(name: name, timestamp: DateTime.utc(2026, 1, 1));

  test('round-trips events through disk', () async {
    final store = AnalyticsQueueStore(path: '${dir.path}/q.json');
    await store.save([e('a'), e('b')]);
    final loaded = await store.load();
    expect(loaded.map((x) => x.name), ['a', 'b']);
  });

  test('load() on a missing file returns empty', () async {
    final store = AnalyticsQueueStore(path: '${dir.path}/nope.json');
    expect(await store.load(), isEmpty);
  });

  test('save trims to maxEvents, keeping the newest', () async {
    final store = AnalyticsQueueStore(path: '${dir.path}/q.json', maxEvents: 2);
    await store.save([e('a'), e('b'), e('c')]);
    final loaded = await store.load();
    expect(loaded.map((x) => x.name), ['b', 'c']);
  });

  test('clear removes the persisted queue', () async {
    final store = AnalyticsQueueStore(path: '${dir.path}/q.json');
    await store.save([e('a')]);
    await store.clear();
    expect(await store.load(), isEmpty);
  });
}
