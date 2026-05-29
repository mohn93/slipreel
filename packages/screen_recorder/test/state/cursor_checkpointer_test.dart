import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/cursor_checkpointer.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cursor_chk_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  CursorPosition pos(int ms) => CursorPosition(
        x: ms.toDouble(),
        y: ms.toDouble() + 1,
        timestampMicros: ms * 1000,
        isClicked: ms % 10 == 0,
        state: CursorState.arrow,
      );

  test('start creates the file empty; stop without adds leaves it empty', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    await c.stop();
    expect(File(path).readAsStringSync(), isEmpty);
  });

  test('positions are flushed to disk on stop', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    c.add(pos(1));
    c.add(pos(2));
    c.add(pos(3));
    await c.stop();
    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(3));
    expect(lines.first, contains('"x":1.0'));
  });

  test('256-entry burst forces a defensive flush before stop', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    for (var i = 0; i < 300; i++) {
      c.add(pos(i));
    }
    // Without stop, at least the first 256 should already be on disk.
    final sizeBeforeStop = File(path).lengthSync();
    expect(sizeBeforeStop, greaterThan(0));
    await c.stop();
    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(300));
  });

  test('start truncates an existing file (fresh session)', () async {
    final path = '${tmp.path}/c.ndjson';
    await File(path).writeAsString('{"stale":true}\n');
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    await c.stop();
    expect(File(path).readAsStringSync(), isEmpty);
  });

  test('readAll round-trips written positions', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    c.add(pos(1));
    c.add(pos(2));
    await c.stop();
    final back = await CursorCheckpointer.readAll(path);
    expect(back, hasLength(2));
    expect(back.first.x, 1.0);
    expect(back.first.timestampMicros, 1000);
  });

  test('readAll on missing file returns empty', () async {
    final back = await CursorCheckpointer.readAll('${tmp.path}/nope.ndjson');
    expect(back, isEmpty);
  });
}
