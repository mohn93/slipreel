import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
import 'package:slipreel_engine/captions/caption_transcriber.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

import '../../../../state/caption_generation_controller.dart';
import '../../../../state/whisper_model_store.dart';
import '../inspector_widgets.dart';
import 'caption_segment_list.dart';
import 'caption_style_controls.dart';

/// Production wiring: real model store + extractor + transcriber, writing into
/// the app's editor controller. autoDispose so a fresh run per project.
final captionGenerationControllerProvider = StateNotifierProvider.autoDispose<
    CaptionGenerationController, CaptionGenerationStatus>((ref) {
  final editor = ref.read(editorProjectControllerProvider.notifier);
  final store = WhisperModelStore();
  const extractor = CaptionAudioExtractor();
  const transcriber = CaptionTranscriber();
  return CaptionGenerationController(
    editor: editor,
    ensureModel: (onP) => store.ensureModel(onProgress: onP),
    extractAudio: (video, source) => extractor.extract(video, source),
    // `onP` is intentionally dropped: CaptionTranscriber doesn't expose
    // transcription progress yet.
    transcribe: (audio, model, onP) =>
        transcriber.transcribe(audioPath: audio, modelPath: model),
  );
});

/// The Captions inspector tab: generate (STT) + edit + style.
class CaptionsTab extends ConsumerStatefulWidget {
  const CaptionsTab({super.key, required this.videoPath});

  final String videoPath;

  @override
  ConsumerState<CaptionsTab> createState() => _CaptionsTabState();
}

class _CaptionsTabState extends ConsumerState<CaptionsTab> {
  CaptionAudioSource? _selected;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(captionGenerationControllerProvider);
    final sourcesAsync =
        ref.watch(captionAudioSourcesProvider(widget.videoPath));
    final hasCaptions = ref.watch(
      editorProjectControllerProvider.select((s) => s.captions.isNotEmpty),
    );

    return ListView(
      padding: const EdgeInsets.only(right: 12),
      clipBehavior: Clip.none,
      children: [
        const InspectorSectionLabel('Generate'),
        sourcesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(8),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          error: (_, __) => const Text('Could not read the recording audio.'),
          data: (sources) {
            if (sources.isEmpty) {
              return const InspectorPlaceholder(
                icon: Icons.volume_off,
                title: 'No audio',
                body: 'This recording has no audio track to transcribe.',
              );
            }
            final preferred = _selected ??
                ref.read(editorProjectControllerProvider).captionSource;
            final selected =
                (preferred != null && sources.contains(preferred))
                    ? preferred
                    : sources.last;
            final busy = status is! CaptionIdle &&
                status is! CaptionDone &&
                status is! CaptionError;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (sources.length > 1)
                  InspectorChipGroup<CaptionAudioSource>(
                    items: sources,
                    labelOf: (s) => s.label,
                    selected: selected,
                    onSelected: (s) => setState(() => _selected = s),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => ref
                          .read(captionGenerationControllerProvider.notifier)
                          .generate(
                            videoPath: widget.videoPath,
                            source: selected,
                          ),
                  icon: const Icon(Icons.closed_caption, size: 18),
                  label: Text(hasCaptions
                      ? 'Regenerate captions'
                      : 'Generate captions'),
                ),
                const SizedBox(height: 8),
                _StatusLine(status: status),
              ],
            );
          },
        ),
        if (hasCaptions) ...[
          const InspectorSectionDivider(),
          const InspectorSectionLabel('Style'),
          const CaptionStyleControls(),
          const InspectorSectionDivider(),
          const InspectorSectionLabel('Segments'),
          const CaptionSegmentList(),
        ],
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});
  final CaptionGenerationStatus status;

  @override
  Widget build(BuildContext context) {
    final (text, isError) = switch (status) {
      CaptionIdle() => ('', false),
      CaptionDownloadingModel(:final progress) => (
          'Downloading model… ${(progress * 100).round()}%',
          false
        ),
      CaptionExtracting() => ('Extracting audio…', false),
      CaptionTranscribing() => ('Transcribing…', false),
      CaptionDone(:final count) => ('Done — $count segments.', false),
      CaptionError(:final message) => (message, true),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: isError ? Colors.redAccent : kInspectorMuted,
        ),
      ),
    );
  }
}
