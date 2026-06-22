import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
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

typedef EnsureModel = Future<String> Function(
    void Function(double progress)? onProgress);
typedef ExtractAudio = Future<String?> Function(
    String videoPath, CaptionAudioSource source);
typedef Transcribe = Future<List<CaptionSegment>> Function(
    String audioPath, String modelPath,
    void Function(double progress)? onProgress);

/// Orchestrates model → extract → transcribe → write into the editor, exposing
/// step-by-step status for the Captions tab. All side-effecting deps are
/// injected so the flow is unit-testable without network/ffmpeg/whisper.
class CaptionGenerationController extends StateNotifier<CaptionGenerationStatus> {
  CaptionGenerationController({
    required EditorProjectController editor,
    required EnsureModel ensureModel,
    required ExtractAudio extractAudio,
    required Transcribe transcribe,
  })  : _editor = editor,
        _ensureModel = ensureModel,
        _extractAudio = extractAudio,
        _transcribe = transcribe,
        super(const CaptionIdle());

  final EditorProjectController _editor;
  final EnsureModel _ensureModel;
  final ExtractAudio _extractAudio;
  final Transcribe _transcribe;

  Future<void> generate({
    required String videoPath,
    required CaptionAudioSource source,
  }) async {
    try {
      state = const CaptionDownloadingModel(0);
      final model =
          await _ensureModel((p) => state = CaptionDownloadingModel(p));

      state = const CaptionExtracting();
      final audio = await _extractAudio(videoPath, source);
      if (audio == null) {
        state = const CaptionError('No audio could be extracted from this '
            'recording.');
        return;
      }

      state = const CaptionTranscribing();
      final segments = await _transcribe(audio, model, null);

      _editor.setCaptionSource(source);
      _editor.replaceCaptionSegments(segments);
      // Auto-enable captions so the user immediately sees the result.
      _editor.setCaptionStyle(
          _editor.state.captionStyle.copyWith(enabled: true));
      state = CaptionDone(segments.length);
    } catch (e) {
      state = CaptionError(e.toString());
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
