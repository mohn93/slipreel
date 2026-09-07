import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:slipreel_engine/utils/app_logger.dart';

import 'look_template.dart';

class LookTemplateData {
  const LookTemplateData({required this.templates, required this.selectedId});
  final List<LookTemplate> templates; // user templates only
  final String selectedId;
}

class LookTemplateStore {
  LookTemplateStore({String? filePath}) : _explicitPath = filePath;

  static const int schemaVersion = 1;

  final String? _explicitPath;
  String? _resolvedPath;
  bool _writesBlocked = false; // latched when a future-schema file is seen
  Future<void> _writeQueue = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    _writeQueue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<String> _path() async {
    if (_explicitPath != null) return _explicitPath!;
    if (_resolvedPath != null) return _resolvedPath!;
    final dir = await getApplicationSupportDirectory();
    final d = Directory(p.join(dir.path, 'slipreel'));
    if (!await d.exists()) await d.create(recursive: true);
    return _resolvedPath = p.join(d.path, 'look_templates.json');
  }

  Future<LookTemplateData> load() => _enqueue(_load);

  Future<LookTemplateData> _load() async {
    final path = await _path();
    final file = File(path);
    if (!await file.exists()) {
      return const LookTemplateData(templates: [], selectedId: kBuiltinCleanId);
    }
    Map<String, dynamic> json;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const LookTemplateData(
            templates: [], selectedId: kBuiltinCleanId);
      }
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e, st) {
      AppLogger.ui.w('look_templates.json corrupt; backing up', error: e, stackTrace: st);
      await _backupCorrupt(file);
      return const LookTemplateData(templates: [], selectedId: kBuiltinCleanId);
    }

    final v = json['schemaVersion'];
    if (v is int && v > schemaVersion) {
      AppLogger.ui.w('look_templates.json schema $v > $schemaVersion; refusing');
      _writesBlocked = true;
      return const LookTemplateData(templates: [], selectedId: kBuiltinCleanId);
    }

    final rawList = json['templates'];
    final templates = <LookTemplate>[];
    if (rawList is List) {
      for (final e in rawList) {
        try {
          templates.add(
              LookTemplate.fromJson((e as Map).cast<String, dynamic>()));
        } catch (err) {
          AppLogger.ui.w('Skipping unparseable look template entry: $err');
        }
      }
    }
    final selected = json['selectedTemplateId'];
    return LookTemplateData(
      templates: templates,
      selectedId: selected is String ? selected : kBuiltinCleanId,
    );
  }

  Future<void> saveAll(List<LookTemplate> userTemplates, String selectedId) =>
      _enqueue(() async {
        if (_writesBlocked) {
          AppLogger.ui.w('look_templates write blocked (future schema)');
          return;
        }
        final path = await _path();
        final tmp = File('$path.tmp');
        final payload = jsonEncode({
          'schemaVersion': schemaVersion,
          'selectedTemplateId': selectedId,
          'templates': [for (final t in userTemplates) t.toJson()],
        });
        await tmp.writeAsString(payload, flush: true);
        await tmp.rename(path);
      });

  Future<void> _backupCorrupt(File file) async {
    try {
      final backup = '${file.path}.corrupt-'
          '${DateTime.now().millisecondsSinceEpoch}';
      await file.rename(backup);
    } catch (e, st) {
      AppLogger.ui.w('Failed to back up corrupt look_templates.json',
          error: e, stackTrace: st);
    }
  }
}
