import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:screen_recorder/state/look_template_controller.dart';
import 'package:screen_recorder/state/look_template_store.dart';
import 'package:slipreel_engine/state/editor_look.dart';

Future<LookTemplateController> _fresh() async {
  final dir = await Directory.systemTemp.createTemp('ltc');
  addTearDown(() => dir.delete(recursive: true));
  final store = LookTemplateStore(filePath: '${dir.path}/look_templates.json');
  final initial = await store.load();
  return LookTemplateController(store: store, initial: initial);
}

void main() {
  test('built-ins listed first, users sorted by name', () async {
    final c = await _fresh();
    await c.saveNew('Zulu', EditorLook.defaults());
    await c.saveNew('alpha', EditorLook.defaults());
    final ids = c.state.all.map((t) => t.id).toList();
    // First three are built-ins.
    expect(ids.take(3), [kBuiltinCleanId, kBuiltinShowcaseId, kBuiltinMinimalId]);
    // Users sorted case-insensitively: alpha before Zulu.
    final names = c.state.all.skip(3).map((t) => t.name).toList();
    expect(names, ['alpha', 'Zulu']);
  });

  test('update and rename ignore built-ins', () async {
    final c = await _fresh();
    await c.update(kBuiltinCleanId, EditorLook.defaults()); // no throw, no-op
    await c.rename(kBuiltinCleanId, 'Hacked');
    expect(
      c.state.all.firstWhere((t) => t.id == kBuiltinCleanId).name,
      'Clean',
    );
  });

  test('delete selected falls back to Clean', () async {
    final c = await _fresh();
    final t = await c.saveNew('Temp', EditorLook.defaults());
    c.select(t.id);
    expect(c.state.selectedId, t.id);
    await c.delete(t.id);
    expect(c.state.selectedId, kBuiltinCleanId);
    expect(c.state.all.any((x) => x.id == t.id), isFalse);
  });

  test('duplicate copies a built-in as a user template', () async {
    final c = await _fresh();
    final dup = await c.duplicate(kBuiltinShowcaseId);
    expect(dup.builtIn, isFalse);
    expect(dup.name, 'Showcase copy');
    expect(dup.look.defaultZoomLook, c.state.all[1].look.defaultZoomLook);
  });
}
