// packages/screen_recorder/lib/state/recovery_service.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import 'cursor_checkpointer.dart';
import 'session_marker.dart';

typedef RunProcess = Future<ProcessResult> Function(
    String executable, List<String> arguments);

class RecoveryCandidate {
  const RecoveryCandidate({
    required this.marker,
    required this.videoBytes,
  });
  final SessionMarker marker;
  final int videoBytes;
}

class RecoveryService {
  RecoveryService({
    required this.markerStore,
    RunProcess? runProcess,
  }) : runProcess = runProcess ?? Process.run;

  final SessionMarkerStore markerStore;
  final RunProcess runProcess;

  /// Scan persisted markers and return the recoverable subset. Removes stale
  /// markers (missing or zero-byte video) as a side effect.
  Future<List<RecoveryCandidate>> scan() async {
    try {
      final markers = await markerStore.load();
      final out = <RecoveryCandidate>[];
      for (final m in markers) {
        final f = File(m.videoPath);
        if (!f.existsSync() || f.lengthSync() == 0) {
          await markerStore.remove(m.id);
          continue;
        }
        out.add(RecoveryCandidate(marker: m, videoBytes: f.lengthSync()));
      }
      return out;
    } catch (e, st) {
      AppLogger.platform.e('RecoveryService.scan failed; treating as no candidates',
          error: e, stackTrace: st);
      return const [];
    }
  }

  /// Re-mux the partial into a clean MP4, rebuild the cursor sidecar, append
  /// to history. Returns the recovered video path on success, null on failure.
  Future<String?> recover(
      RecoveryCandidate candidate, RecordingHistoryStore history) async {
    final partial = candidate.marker.videoPath;
    final recovered = partial.replaceFirst(RegExp(r'\.mp4$'), '.recovered.mp4');
    try {
      final ffmpeg = Ffmpeg.resolve();
      final result = await runProcess(ffmpeg, [
        '-y',
        '-i', partial,
        '-c', 'copy',
        '-f', 'mp4',
        '-movflags', '+faststart',
        recovered,
      ]);
      if (result.exitCode != 0 || !File(recovered).existsSync()) {
        AppLogger.platform.w('Recovery re-mux failed: ${result.stderr}');
        return null;
      }
    } catch (e, st) {
      AppLogger.platform.e('Recovery ffmpeg invocation threw',
          error: e, stackTrace: st);
      return null;
    }

    // Probe duration for the .meta.json sidecar.
    double? recoveredDurationSeconds;
    try {
      final ffprobePath = Ffmpeg.resolve().replaceFirst(RegExp(r'ffmpeg$'), 'ffprobe');
      final probe = await runProcess(ffprobePath, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=nokey=1:noprint_wrappers=1',
        recovered,
      ]);
      if (probe.exitCode == 0) {
        recoveredDurationSeconds = double.tryParse(probe.stdout.toString().trim());
      }
    } catch (e, st) {
      AppLogger.platform.w('ffprobe of recovered file failed',
          error: e, stackTrace: st);
    }

    // Rebuild the cursor sidecar from the NDJSON, if present.
    try {
      final positions =
          await CursorCheckpointer.readAll(candidate.marker.cursorNdjsonPath);
      if (positions.isNotEmpty) {
        final rec = CursorRecording();
        for (final p in positions) {
          rec.addPosition(p);
        }
        await rec.saveToFile('$recovered.cursor.json');
      }
    } catch (e, st) {
      AppLogger.platform.w('Cursor restore failed; recovered clip has no cursor',
          error: e, stackTrace: st);
    }

    // Write the .meta.json sidecar so the editor / Recents have a duration.
    if (recoveredDurationSeconds != null) {
      try {
        final meta = RecordingMetadata(
          isPureSource: true,
          recordedAt: candidate.marker.startedAt,
          widthPx: candidate.marker.width,
          heightPx: candidate.marker.height,
          fps: candidate.marker.fps,
          duration: Duration(milliseconds: (recoveredDurationSeconds * 1000).round()),
        );
        await meta.saveForVideo(recovered);
      } catch (e, st) {
        AppLogger.platform.w('Recovered .meta.json write failed',
            error: e, stackTrace: st);
      }
    }

    // Append to history.
    await history.append(RecordingHistoryEntry(
      videoPath: recovered,
      recordedAt: candidate.marker.startedAt,
      widthPx: candidate.marker.width,
      heightPx: candidate.marker.height,
      fps: candidate.marker.fps,
    ));

    // Clean up the originals + marker.
    await _safeDelete(partial);
    await _safeDelete(candidate.marker.cursorNdjsonPath);
    await markerStore.remove(candidate.marker.id);
    return recovered;
  }

  /// Drop the partial files + marker. The user chose to discard.
  Future<void> discard(RecoveryCandidate candidate) async {
    await _safeDelete(candidate.marker.videoPath);
    await _safeDelete(candidate.marker.cursorNdjsonPath);
    await markerStore.remove(candidate.marker.id);
  }

  Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (e) {
      AppLogger.platform.w('Failed to delete $path: $e');
    }
  }
}

final recoveryServiceProvider = Provider<RecoveryService>(
  (ref) => throw UnimplementedError('Override recoveryServiceProvider in main()'),
);
