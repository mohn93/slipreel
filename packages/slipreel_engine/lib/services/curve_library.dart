import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// Identifies a curve in chip rows and editor state. The same record
/// shape is used for built-ins and for user-saved entries.
class NamedCurve {
  const NamedCurve({
    required this.id,
    required this.name,
    required this.curve,
  });
  final String id;
  final String name;
  final CubicBezierCurve curve;
}

abstract class CurveLibrary {
  Future<List<NamedCurve>> list();
  Future<NamedCurve> save({required String name, required CubicBezierCurve curve});
  Future<void> delete(String id);
}

class FileCurveLibrary implements CurveLibrary {
  FileCurveLibrary({String? filePath}) : _explicitPath = filePath;

  final String? _explicitPath;
  String? _resolvedPath;
  final Random _rng = Random.secure();

  Future<void> _writeQueue = Future.value();

  /// Serialize mutations so two concurrent save/rename/delete calls
  /// can never both `await list()` against the same on-disk state and
  /// then race to overwrite each other.
  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    // Swallow errors on the queue so a failed op doesn't poison
    // subsequent ops; the original error still propagates to the caller
    // via `next`.
    _writeQueue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<String> _path() async {
    final explicit = _explicitPath;
    if (explicit != null) return explicit;
    final resolved = _resolvedPath;
    if (resolved != null) return resolved;
    final dir = await getApplicationSupportDirectory();
    final sub = Directory('${dir.path}/slipreel');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    _resolvedPath = '${sub.path}/curves.json';
    return _resolvedPath!;
  }

  @override
  Future<List<NamedCurve>> list() async {
    final f = File(await _path());
    if (!await f.exists()) return const [];
    try {
      final raw = await f.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final entries = (json['curves'] as List<dynamic>? ?? const []);
      return entries
          .whereType<Map<String, dynamic>>()
          .map((e) => NamedCurve(
                id: e['id'] as String,
                name: e['name'] as String,
                curve: CubicBezierCurve(
                  x1: (e['x1'] as num).toDouble(),
                  y1: (e['y1'] as num).toDouble(),
                  x2: (e['x2'] as num).toDouble(),
                  y2: (e['y2'] as num).toDouble(),
                ),
              ))
          .toList(growable: false);
    } catch (e, st) {
      AppLogger.ui.w('curves.json corrupt — returning empty list',
          error: e, stackTrace: st);
      return const [];
    }
  }

  @override
  Future<NamedCurve> save({
    required String name,
    required CubicBezierCurve curve,
  }) {
    return _enqueue(() async {
      final entries = [...await list()];
      final id = _newId();
      final entry = NamedCurve(id: id, name: name, curve: curve);
      entries.add(entry);
      await _write(entries);
      return entry;
    });
  }

  @override
  Future<void> delete(String id) {
    return _enqueue(() async {
      final entries = await list();
      final next = entries.where((e) => e.id != id).toList(growable: false);
      await _write(next);
    });
  }

  Future<void> _write(List<NamedCurve> entries) async {
    final path = await _path();
    final tmp = File('$path.tmp');
    final json = {
      'version': 1,
      'curves': entries
          .map((e) => {
                'id': e.id,
                'name': e.name,
                'x1': e.curve.x1,
                'y1': e.curve.y1,
                'x2': e.curve.x2,
                'y2': e.curve.y2,
              })
          .toList(),
    };
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(path);
  }

  String _newId() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// CSS-standard easings rendered first in the editor's chip row.
/// They never appear in the on-disk library file.
class BuiltInCurves {
  static const List<NamedCurve> all = [
    NamedCurve(
      id: 'linear',
      name: 'Linear',
      curve: CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease',
      name: 'Ease',
      curve: CubicBezierCurve(x1: 0.25, y1: 0.10, x2: 0.25, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-in',
      name: 'Ease in',
      curve: CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 1.0, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-out',
      name: 'Ease out',
      curve: CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-in-out',
      name: 'Ease in-out',
      curve: CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
    ),
  ];

  static NamedCurve? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}
