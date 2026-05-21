import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// Per-recording project store backed by a `<videoPath>.editor.json`
/// sidecar.
///
/// One instance per recording. `load()` returns the saved state or
/// [EditorProjectState.defaults] on missing/corrupt files (a corrupt
/// file is logged and replaced; a missing one is the normal case for
/// fresh recordings).
///
/// Writes are atomic (write to `*.tmp`, then rename) and serialized
/// through an internal mutation queue, mirroring the [FileCurveLibrary]
/// pattern — concurrent saves are a real risk because the inspector
/// debounces but a save can still overlap a fresh edit.
class EditorProjectStore {
  EditorProjectStore({required this.videoPath});

  final String videoPath;

  String get sidecarPath => '$videoPath.editor.json';

  Future<EditorProjectState> load() async {
    final f = File(sidecarPath);
    if (!await f.exists()) {
      return EditorProjectState.defaults();
    }
    try {
      final text = await f.readAsString();
      if (text.trim().isEmpty) {
        return EditorProjectState.defaults();
      }
      final json = jsonDecode(text) as Map<String, dynamic>;
      return EditorProjectState.fromJson(json);
    } catch (e, stack) {
      AppLogger.ui.w(
        'EditorProjectStore: failed to load $sidecarPath, using defaults',
        error: e,
        stackTrace: stack,
      );
      return EditorProjectState.defaults();
    }
  }

  Future<void> _writeQueue = Future.value();
  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    // Swallow errors so a single failed save doesn't poison the chain.
    _writeQueue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<void> save(EditorProjectState state) {
    return _enqueue(() async {
      final tmp = File('$sidecarPath.tmp');
      try {
        await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
        await tmp.rename(sidecarPath);
      } catch (e, stack) {
        AppLogger.ui.e(
          'EditorProjectStore: save to $sidecarPath failed',
          error: e,
          stackTrace: stack,
        );
        // Best-effort cleanup; ignore errors here since the rename
        // may have already moved the tmp file out from under us.
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        rethrow;
      }
    });
  }
}
