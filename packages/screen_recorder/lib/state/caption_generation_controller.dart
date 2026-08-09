import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
import 'package:slipreel_engine/captions/caption_transcriber.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

/// Progress/result of an auto-caption run.
sealed class CaptionGenerationStatus {
  const CaptionGenerationStatus();
}

class CaptionIdle extends CaptionGenerationStatus {
  const CaptionIdle();
}

class CaptionDownloadingModel extends CaptionGenerationStatus {
  const CaptionDownloadingModel(this.progress);
  final double progress;
}

class CaptionExtracting extends CaptionGenerationStatus {
  const CaptionExtracting();
}

class CaptionTranscribing extends CaptionGenerationStatus {
  const CaptionTranscribing();
}

class CaptionDone extends CaptionGenerationStatus {
  const CaptionDone(this.count);
  final int count;
}

class CaptionError extends CaptionGenerationStatus {
  const CaptionError(this.message);
  final String message;
}

/// The user cancelled the run (or the tab was disposed mid-run). The
/// whisper/ffmpeg subprocess was killed; nothing was written.
class CaptionCancelled extends CaptionGenerationStatus {
  const CaptionCancelled();
}

typedef EnsureModel = Future<String> Function(
    void Function(double progress)? onProgress);
typedef ExtractAudio = Future<String?> Function(
    String videoPath, CaptionAudioSource source, CancelToken? cancelToken);
typedef Transcribe = Future<List<CaptionSegment>> Function(
    String audioPath, String modelPath,
    void Function(double progress)? onProgress, CancelToken? cancelToken);

/// Resolves the microsecond offset to add to whisper timestamps so they land on
/// movie-time (the recording's audio leading-gap). See `captionAudioOffsetMicros`.
typedef AudioOffset = Future<int> Function(
    String videoPath, CaptionAudioSource source);

/// Orchestrates model → extract → transcribe → write into the editor, exposing
/// step-by-step status for the Captions tab. All side-effecting deps are
/// injected so the flow is unit-testable without network/ffmpeg/whisper.
class CaptionGenerationController extends StateNotifier<CaptionGenerationStatus> {
  CaptionGenerationController({
    required EditorProjectController editor,
    required EnsureModel ensureModel,
    required ExtractAudio extractAudio,
    required Transcribe transcribe,
    required AudioOffset audioOffset,
  })  : _editor = editor,
        _ensureModel = ensureModel,
        _extractAudio = extractAudio,
        _transcribe = transcribe,
        _audioOffset = audioOffset,
        super(const CaptionIdle());

  final EditorProjectController _editor;
  final EnsureModel _ensureModel;
  final ExtractAudio _extractAudio;
  final Transcribe _transcribe;
  final AudioOffset _audioOffset;

  /// Token for the in-flight [generate] run; fired by [cancel]/[dispose].
  CancelToken? _activeCancel;

  /// Cancels the in-flight generation: the extractor/transcriber
  /// subprocess is killed and the run lands in [CaptionCancelled].
  /// No-op when idle.
  void cancel() => _activeCancel?.cancel();

  @override
  void dispose() {
    // The Captions tab's provider is autoDispose: closing the tab must
    // kill a running whisper (minutes of pinned CPU on long recordings)
    // instead of orphaning it.
    _activeCancel?.cancel();
    super.dispose();
  }

  /// Sets [state] only while this notifier is still mounted — a
  /// dispose-triggered cancel resolves after dispose, when setting
  /// state would throw.
  void _setState(CaptionGenerationStatus next) {
    if (mounted) state = next;
  }

  Future<void> generate({
    required String videoPath,
    required CaptionAudioSource source,
  }) async {
    final cancelToken = _activeCancel = CancelToken();
    String? audio;
    try {
      _setState(const CaptionDownloadingModel(0));
      final model =
          await _ensureModel((p) => _setState(CaptionDownloadingModel(p)));

      _setState(const CaptionExtracting());
      audio = await _extractAudio(videoPath, source, cancelToken);
      if (audio == null) {
        _setState(const CaptionError('No audio could be extracted from this '
            'recording.'));
        return;
      }

      _setState(const CaptionTranscribing());
      final segments = await _transcribe(audio, model, null, cancelToken);
      // Map whisper's WAV-relative times onto movie-time by re-adding the
      // recording's audio leading-gap, so captions line up with the audio in
      // both the preview and the export.
      final offsetMicros = await _audioOffset(videoPath, source);
      final shifted = shiftCaptionSegments(segments, offsetMicros);

      _editor.setCaptionSource(source);
      _editor.replaceCaptionSegments(shifted);
      // Auto-enable captions so the user immediately sees the result.
      _editor.setCaptionStyle(
          _editor.state.captionStyle.copyWith(enabled: true));
      _setState(CaptionDone(segments.length));
    } on CaptionCancelledException {
      _setState(const CaptionCancelled());
    } catch (e) {
      _setState(CaptionError(e.toString()));
    } finally {
      _activeCancel = null;
      _cleanupCaptionTemp(audio);
    }
  }

  /// Removes the extractor's `slipreel_caption_*` temp dir (WAV +
  /// whisper transcript). Without this, every generation — including
  /// every failed retry — leaked a fresh dir holding ~2 MB per minute
  /// of extracted audio. Only deletes directories matching our naming
  /// convention so an injected `outPath` outside it is never touched.
  static void _cleanupCaptionTemp(String? audioPath) {
    if (audioPath == null) return;
    try {
      final dir = File(audioPath).parent;
      if (!p.basename(dir.path).startsWith('slipreel_caption_')) return;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort; the OS temp reaper is the fallback.
    }
  }

  void reset() => state = const CaptionIdle();
}

/// Caption sources available for [videoPath], from its audio-stream count.
final captionAudioSourcesProvider = FutureProvider.autoDispose
    .family<List<CaptionAudioSource>, String>((ref, videoPath) async {
  try {
    final probe = await ffmpegProbe(path: videoPath);
    return availableCaptionSources(probe.audioStreams.length);
  } catch (_) {
    return const [];
  }
});
