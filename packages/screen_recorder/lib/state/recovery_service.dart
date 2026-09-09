// packages/screen_recorder/lib/state/recovery_service.dart
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import 'cursor_checkpointer.dart';
import 'session_marker.dart';

typedef RunProcess =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class RecoveryCandidate {
  const RecoveryCandidate({required this.marker, required this.videoBytes});
  final SessionMarker marker;
  final int videoBytes;
}

class RecoveryService {
  RecoveryService({required this.markerStore, RunProcess? runProcess})
    : runProcess = runProcess ?? Process.run;

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
      AppLogger.platform.e(
        'RecoveryService.scan failed; treating as no candidates',
        error: e,
        stackTrace: st,
      );
      return const [];
    }
  }

  /// Re-mux the partial into a clean MP4, rebuild the cursor sidecar, append
  /// to history. Returns the recovered video path on success, null on failure.
  Future<String?> recover(
    RecoveryCandidate candidate,
    RecordingHistoryStore history,
  ) async {
    final partial = candidate.marker.videoPath;
    final dir = await File(partial).parent.createTemp('Recovered-');
    String? result;
    try {
      result = await _recover(candidate, history, dir);
      return result;
    } finally {
      if (result == null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  Future<String?> _recover(
    RecoveryCandidate candidate,
    RecordingHistoryStore history,
    Directory dir,
  ) async {
    final partial = candidate.marker.videoPath;
    final recovered = p.join(
      dir.path,
      '${p.basenameWithoutExtension(partial)}.recovered.mp4',
    );
    final sourceStreams = await _probeStreams(partial);
    if (sourceStreams == null) return null;
    try {
      final ffmpeg = Ffmpeg.resolve();
      final result = await runProcess(ffmpeg, [
        '-y',
        '-i',
        partial,
        '-map',
        '0:v',
        '-map',
        '0:a?',
        '-c',
        'copy',
        '-f',
        'mp4',
        '-movflags',
        '+faststart',
        recovered,
      ]);
      if (result.exitCode != 0 || !File(recovered).existsSync()) {
        AppLogger.platform.w('Recovery re-mux failed: ${result.stderr}');
        return null;
      }
    } catch (e, st) {
      AppLogger.platform.e(
        'Recovery ffmpeg invocation threw',
        error: e,
        stackTrace: st,
      );
      return null;
    }

    final recoveredStreams = await _probeStreams(recovered);
    if (recoveredStreams == null ||
        sourceStreams['video'] != recoveredStreams['video'] ||
        sourceStreams['audio'] != recoveredStreams['audio']) {
      AppLogger.platform.w(
        'Recovered stream validation failed; original retained.',
      );
      return null;
    }
    final camera = File(CameraSidecarMeta.moviePathForVideo(partial));
    if (await camera.exists()) {
      // Keep the originals and recovery marker if any camera data cannot be
      // restored. Never silently turn a camera project into a screen-only clip.
      try {
        final target = CameraSidecarMeta.moviePathForVideo(recovered);
        final result = await runProcess(Ffmpeg.resolve(), [
          '-y',
          '-i',
          camera.path,
          '-map',
          '0:v',
          '-c',
          'copy',
          target,
        ]);
        final streams = await _probeStreams(target);
        if (result.exitCode != 0 || streams == null || streams['video'] != 1) {
          return null;
        }
        var meta = await CameraSidecarMeta.loadForVideo(partial);
        if (meta == null) {
          final cameraHost = double.parse(
            await File('${camera.path}.start-time').readAsString(),
          );
          final screenHost = double.parse(
            await File('$partial.start-time').readAsString(),
          );
          meta = CameraSidecarMeta(
            deviceLabel: candidate.marker.cameraDeviceLabel ?? 'Camera',
            width: streams['width']!,
            height: streams['height']!,
            frameCount: streams['frames']!,
            offsetMicros: ((cameraHost - screenHost) * 1000000).round(),
            selfViewX: 0.82,
            selfViewY: 0.82,
          );
        }
        await meta.saveForVideo(recovered);
      } catch (e) {
        AppLogger.platform.w('Camera recovery failed; originals retained: $e');
        return null;
      }
    }

    // Probe duration for the .meta.json sidecar.
    double? recoveredDurationSeconds;
    try {
      final ffprobePath = Ffmpeg.resolveProbe();
      final probe = await runProcess(ffprobePath, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=nokey=1:noprint_wrappers=1',
        recovered,
      ]);
      if (probe.exitCode == 0) {
        recoveredDurationSeconds = double.tryParse(
          probe.stdout.toString().trim(),
        );
      }
    } catch (e, st) {
      AppLogger.platform.w(
        'ffprobe of recovered file failed',
        error: e,
        stackTrace: st,
      );
    }

    // Rebuild the cursor sidecar from the NDJSON, if present.
    try {
      final positions = await CursorCheckpointer.readAll(
        candidate.marker.cursorNdjsonPath,
      );
      if (positions.isNotEmpty) {
        final rec = CursorRecording();
        for (final p in positions) {
          rec.addPosition(p);
        }
        await rec.saveToFile('$recovered.cursor.json');
      }
    } catch (e, st) {
      AppLogger.platform.w(
        'Cursor restore failed; original retained',
        error: e,
        stackTrace: st,
      );
      return null;
    }

    if (recoveredDurationSeconds == null || recoveredDurationSeconds <= 0) {
      return null;
    }

    // Write the .meta.json sidecar so the editor / Recents have a duration.
    {
      try {
        final meta = RecordingMetadata(
          isPureSource: true,
          isDeviceCapture: candidate.marker.isDeviceCapture,
          recordedAt: candidate.marker.startedAt,
          widthPx: candidate.marker.width,
          heightPx: candidate.marker.height,
          fps: candidate.marker.fps,
          duration: Duration(
            milliseconds: (recoveredDurationSeconds * 1000).round(),
          ),
        );
        await meta.saveForVideo(recovered);
      } catch (e, st) {
        AppLogger.platform.w(
          'Recovered .meta.json write failed',
          error: e,
          stackTrace: st,
        );
        return null;
      }
    }

    // Append to history.
    await history.append(
      RecordingHistoryEntry(
        videoPath: recovered,
        recordedAt: candidate.marker.startedAt,
        widthPx: candidate.marker.width,
        heightPx: candidate.marker.height,
        fps: candidate.marker.fps,
      ),
    );

    // Clean up the originals + marker.
    await _safeDelete(partial);
    await _safeDelete(camera.path);
    await _safeDelete('$partial.camera.json');
    await _safeDelete('$partial.start-time');
    await _safeDelete('${camera.path}.start-time');
    await _safeDelete(candidate.marker.cursorNdjsonPath);
    try {
      await markerStore.remove(candidate.marker.id);
    } catch (e) {
      // History already owns the recovered files. A marker cleanup failure
      // must never make the outer cleanup remove this committed recovery.
      AppLogger.platform.w(
        'Recovered media saved; stale marker cleanup failed: $e',
      );
    }
    return recovered;
  }

  /// Drop the partial files + marker. The user chose to discard.
  Future<void> discard(RecoveryCandidate candidate) async {
    final partial = candidate.marker.videoPath;
    await _safeDelete(partial);
    await _safeDelete('$partial.camera.mov');
    await _safeDelete('$partial.camera.json');
    await _safeDelete('$partial.start-time');
    await _safeDelete('$partial.camera.mov.start-time');
    await _safeDelete(candidate.marker.cursorNdjsonPath);
    await markerStore.remove(candidate.marker.id);
  }

  Future<Map<String, int>?> _probeStreams(String path) async {
    try {
      final result = await runProcess(Ffmpeg.resolveProbe(), [
        '-v',
        'error',
        '-show_entries',
        'stream=codec_type,width,height,nb_read_frames',
        '-count_frames',
        '-of',
        'json',
        path,
      ]);
      if (result.exitCode != 0) return null;
      final streams =
          (jsonDecode(result.stdout.toString())
                  as Map<String, dynamic>)['streams']
              as List;
      final videos = streams.where((s) => s['codec_type'] == 'video').toList();
      if (videos.isEmpty) return null;
      return {
        'video': videos.length,
        'frames':
            int.tryParse(videos.first['nb_read_frames']?.toString() ?? '') ?? 0,
        'audio': streams.where((s) => s['codec_type'] == 'audio').length,
        'width': (videos.first['width'] as num?)?.toInt() ?? 0,
        'height': (videos.first['height'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return null;
    }
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
  (ref) =>
      throw UnimplementedError('Override recoveryServiceProvider in main()'),
);
