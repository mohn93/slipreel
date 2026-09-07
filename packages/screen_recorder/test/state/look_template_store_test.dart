import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:screen_recorder/state/look_template_store.dart';
import 'package:slipreel_engine/state/editor_look.dart';

LookTemplate _user(String id, String name) => LookTemplate(
      id: id,
      name: name,
      builtIn: false,
      look: EditorLook.defaults(),
      updatedAt: DateTime.utc(2026, 9, 6),
    );

void main() {
  test('empty file yields no templates and Clean selection', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final store = LookTemplateStore(filePath: '${dir.path}/look_templates.json');
    final data = await store.load();
    expect(data.templates, isEmpty);
    expect(data.selectedId, kBuiltinCleanId);
  });

  test('round-trips user templates and selection', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    final store = LookTemplateStore(filePath: path);
    await store.saveAll([_user('a', 'A'), _user('b', 'B')], 'b');
    final data = await LookTemplateStore(filePath: path).load();
    expect(data.templates.map((t) => t.id), ['a', 'b']);
    expect(data.selectedId, 'b');
    // No leftover tmp file.
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('corrupt file is backed up and yields empty', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    await File(path).writeAsString('{ not json');
    final data = await LookTemplateStore(filePath: path).load();
    expect(data.templates, isEmpty);
    expect(
      dir.listSync().whereType<File>().any(
          (f) => f.path.contains('look_templates.json.corrupt-')),
      isTrue,
    );
  });

  test('one bad entry is skipped, others survive', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    final good = _user('a', 'A').toJson();
    await File(path).writeAsString(jsonEncode({
      'schemaVersion': 1,
      'selectedTemplateId': 'a',
      'templates': [good, {'garbage': true}],
    }));
    final data = await LookTemplateStore(filePath: path).load();
    expect(data.templates.map((t) => t.id), ['a']);
  });

  test('future schema refuses to load or write', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    await File(path).writeAsString(jsonEncode({
      'schemaVersion': 999,
      'selectedTemplateId': 'a',
      'templates': [_user('a', 'A').toJson()],
    }));
    final store = LookTemplateStore(filePath: path);
    final data = await store.load();
    expect(data.templates, isEmpty); // refused
    // Write is refused for this session — file content unchanged.
    await store.saveAll([_user('z', 'Z')], 'z');
    final raw = jsonDecode(await File(path).readAsString());
    expect(raw['schemaVersion'], 999);
  });
}
