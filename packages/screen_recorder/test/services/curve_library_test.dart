import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';

void main() {
  group('BuiltInCurves', () {
    test('exposes the five CSS standard easings in a stable order', () {
      final ids = BuiltInCurves.all.map((e) => e.id).toList();
      expect(ids, [
        'linear',
        'ease',
        'ease-in',
        'ease-out',
        'ease-in-out',
      ]);
    });

    test('each built-in resolves to a CubicBezierCurve with known params', () {
      final ease = BuiltInCurves.byId('ease')!;
      // CSS "ease" = cubic-bezier(0.25, 0.1, 0.25, 1.0)
      expect(ease.curve.x1, closeTo(0.25, 1e-9));
      expect(ease.curve.y1, closeTo(0.10, 1e-9));
      expect(ease.curve.x2, closeTo(0.25, 1e-9));
      expect(ease.curve.y2, closeTo(1.00, 1e-9));
    });

    test('byId returns null for unknown id', () {
      expect(BuiltInCurves.byId('nope'), isNull);
    });
  });

  group('FileCurveLibrary', () {
    late Directory tempDir;
    late FileCurveLibrary lib;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('curve_lib_test_');
      lib = FileCurveLibrary(filePath: '${tempDir.path}/curves.json');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('save then list returns the saved curve', () async {
      const c = CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4);
      final saved = await lib.save(name: 'snap-back', curve: c);
      expect(saved.name, 'snap-back');
      expect(saved.curve, c);

      final list = await lib.list();
      expect(list, hasLength(1));
      expect(list.first.id, saved.id);
      expect(list.first.curve, c);
    });

    test('save assigns unique ids', () async {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      final a = await lib.save(name: 'a', curve: c);
      final b = await lib.save(name: 'b', curve: c);
      expect(a.id, isNot(b.id));
    });

    test('delete removes the entry', () async {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      final saved = await lib.save(name: 'x', curve: c);
      await lib.delete(saved.id);
      expect(await lib.list(), isEmpty);
    });

    test('atomic write leaves no .tmp on success', () async {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      await lib.save(name: 'x', curve: c);
      final tmp = File('${tempDir.path}/curves.json.tmp');
      expect(await tmp.exists(), isFalse);
    });

    test('corrupt JSON yields empty list, not a throw', () async {
      final f = File('${tempDir.path}/curves.json');
      await f.writeAsString('not json{{');
      expect(await lib.list(), isEmpty);
    });

    test('schema version 1 is written on save', () async {
      const c = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      await lib.save(name: 'v1', curve: c);
      final raw = await File('${tempDir.path}/curves.json').readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['version'], 1);
    });

    test('concurrent saves do not lose entries', () async {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      // Kick off many saves without awaiting between them. Without the
      // mutation queue, the read-modify-write pattern in save() loses
      // most of these.
      await Future.wait(List.generate(
        20,
        (i) => lib.save(name: 'c$i', curve: c),
      ));
      expect(await lib.list(), hasLength(20));
    });

    test('save self-heals when an orphaned .tmp file exists', () async {
      // Simulate a crash mid-write that left a stale .tmp file.
      final stale = File('${tempDir.path}/curves.json.tmp');
      await stale.writeAsString('partial garbage');

      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      await lib.save(name: 'after-crash', curve: c);

      // Save succeeds; final curves.json is well-formed; no .tmp leftover.
      expect(await stale.exists(), isFalse);
      final list = await lib.list();
      expect(list, hasLength(1));
      expect(list.first.name, 'after-crash');
    });
  });
}
