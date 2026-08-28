import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/license_store.dart';

void main() {
  test('FileSecureKV round-trips and persists across instances', () async {
    final dir = await Directory.systemTemp.createTemp('slipreel_kv');
    final path = '${dir.path}/nested/licensing.json';
    final kv = FileSecureKV(path);

    expect(await kv.read('a'), isNull);
    await kv.write('a', '1');
    await kv.write('b', '2');
    expect(await kv.read('a'), '1');

    // A fresh instance reads the persisted file (parent dir auto-created).
    expect(await FileSecureKV(path).read('b'), '2');

    await kv.delete('a');
    expect(await FileSecureKV(path).read('a'), isNull);
    expect(await FileSecureKV(path).read('b'), '2');

    await dir.delete(recursive: true);
  });

  test('FileSecureKV treats a corrupt/missing file as empty and stays writable',
      () async {
    final dir = await Directory.systemTemp.createTemp('slipreel_kv');
    final path = '${dir.path}/licensing.json';
    await File(path).writeAsString('{ not json');

    final kv = FileSecureKV(path);
    expect(await kv.read('x'), isNull);
    await kv.write('x', 'ok');
    expect(await FileSecureKV(path).read('x'), 'ok');

    await dir.delete(recursive: true);
  });
}
