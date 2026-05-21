import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// File-backed persistence for [MotionTuning].
///
/// Used to close the designer-iteration loop for motion-feel tuning:
/// edit a sidecar JSON, restart the app, see the new feel — without
/// recompiling. App startup calls [load] and seeds
/// [motionTuningProvider] via a `ProviderScope` override; the UI
/// preset picker calls [save] to persist the user's choice across
/// sessions.
///
/// `load()` returns `null` when the file is missing or corrupt — the
/// caller seeds with [MotionTuning.defaults] in that case. A corrupt
/// file is logged (not thrown) so a malformed user-edited JSON
/// degrades to "no override" rather than crashing the app.
///
/// Writes are atomic (write to `*.tmp`, then rename) and serialised
/// through an internal mutation queue, mirroring [EditorProjectStore]
/// — two near-simultaneous picker clicks can't tear the file.
class MotionTuningStore {
  MotionTuningStore({required this.path});

  /// Filesystem path to the sidecar JSON. Caller picks the location
  /// (typically `~/.../prefs/motion_tuning.json` via path_provider).
  final String path;

  Future<MotionTuning?> load() async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      final text = await f.readAsString();
      if (text.trim().isEmpty) return null;
      final json = jsonDecode(text) as Map<String, dynamic>;
      return MotionTuning.fromJson(json);
    } catch (e, stack) {
      AppLogger.ui.w(
        'MotionTuningStore: failed to load $path, ignoring file',
        error: e,
        stackTrace: stack,
      );
      return null;
    }
  }

  Future<void> _writeQueue = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    // Swallow errors so a single failed save doesn't poison the chain.
    _writeQueue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<void> save(MotionTuning tuning) {
    return _enqueue(() async {
      final tmp = File('$path.tmp');
      try {
        await tmp.writeAsString(
          jsonEncode(tuning.toJson()),
          flush: true,
        );
        await tmp.rename(path);
      } catch (e, stack) {
        AppLogger.ui.w(
          'MotionTuningStore: failed to save $path',
          error: e,
          stackTrace: stack,
        );
        if (await tmp.exists()) {
          await tmp.delete();
        }
      }
    });
  }
}
