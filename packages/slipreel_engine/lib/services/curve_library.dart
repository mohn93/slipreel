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

  static const int _schemaVersion = 1;

  @override
  Future<List<NamedCurve>> list() async => (await _load()).curves;

  /// Loads the library, distinguishing a clean parse (possibly with some
  /// individually-skipped malformed records) from a whole-file failure. A
  /// `fileCorrupt` result means the on-disk bytes could not be read at all —
  /// callers MUST NOT overwrite the file without backing it up first, or a
  /// single unreadable file silently erases every saved curve.
  Future<({List<NamedCurve> curves, bool fileCorrupt})> _load() async {
    final f = File(await _path());
    if (!await f.exists()) {
      return (curves: const <NamedCurve>[], fileCorrupt: false);
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e, st) {
      AppLogger.ui.w('curves.json unreadable — preserving file, treating empty',
          error: e, stackTrace: st);
      return (curves: const <NamedCurve>[], fileCorrupt: true);
    }
    final version = json['version'];
    if (version is int && version > _schemaVersion) {
      // A newer build wrote this. Don't parse-and-rewrite it as v1 — that
      // would drop fields we don't understand. Treat as corrupt so mutations
      // back it up rather than clobber it.
      AppLogger.ui.w('curves.json version $version newer than $_schemaVersion '
          '— preserving file');
      return (curves: const <NamedCurve>[], fileCorrupt: true);
    }
    final entries = (json['curves'] as List<dynamic>? ?? const []);
    final out = <NamedCurve>[];
    for (final e in entries) {
      final parsed = _tryParseEntry(e);
      if (parsed != null) {
        out.add(parsed);
      } else {
        // Drop a single bad record rather than discarding the whole library.
        AppLogger.ui.w('Skipping malformed curve entry: $e');
      }
    }
    return (curves: out, fileCorrupt: false);
  }

  static NamedCurve? _tryParseEntry(dynamic e) {
    if (e is! Map) return null;
    final id = e['id'];
    final name = e['name'];
    final x1 = e['x1'], y1 = e['y1'], x2 = e['x2'], y2 = e['y2'];
    if (id is! String ||
        name is! String ||
        x1 is! num ||
        y1 is! num ||
        x2 is! num ||
        y2 is! num) {
      return null;
    }
    return NamedCurve(
      id: id,
      name: name,
      curve: CubicBezierCurve(
        x1: x1.toDouble(),
        y1: y1.toDouble(),
        x2: x2.toDouble(),
        y2: y2.toDouble(),
      ),
    );
  }

  /// Copies an unreadable curves.json to `curves.json.bak` before a mutation
  /// overwrites it, so a corrupt or newer-version file is recoverable rather
  /// than silently lost.
  Future<void> _backupCorruptFile() async {
    try {
      final path = await _path();
      final f = File(path);
      if (await f.exists()) {
        await f.copy('$path.bak');
        AppLogger.ui.w('Backed up unreadable curves.json to $path.bak');
      }
    } catch (e, st) {
      AppLogger.ui.w('Failed to back up corrupt curves.json',
          error: e, stackTrace: st);
    }
  }

  @override
  Future<NamedCurve> save({
    required String name,
    required CubicBezierCurve curve,
  }) {
    return _enqueue(() async {
      final loaded = await _load();
      if (loaded.fileCorrupt) await _backupCorruptFile();
      final id = _newId();
      final entry = NamedCurve(id: id, name: name, curve: curve);
      await _write([...loaded.curves, entry]);
      return entry;
    });
  }

  @override
  Future<void> delete(String id) {
    return _enqueue(() async {
      final loaded = await _load();
      if (loaded.fileCorrupt) await _backupCorruptFile();
      final next =
          loaded.curves.where((e) => e.id != id).toList(growable: false);
      await _write(next);
    });
  }

  Future<void> _write(List<NamedCurve> entries) async {
    final path = await _path();
    final tmp = File('$path.tmp');
    final json = {
      'version': _schemaVersion,
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
