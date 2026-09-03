import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
import 'package:slipreel_engine/captions/caption_transcriber.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

import '../../../../diagnostics/persistent_crumb_store.dart';
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
    extractAudio: (video, source, cancelToken) =>
        extractor.extract(video, source, cancelToken: cancelToken),
    // `onP` is intentionally dropped: CaptionTranscriber doesn't expose
    // transcription progress yet.
    transcribe: (audio, model, onP, cancelToken) => transcriber.transcribe(
        audioPath: audio, modelPath: model, cancelToken: cancelToken),
    // Probe the chosen source's audio start_time so whisper's WAV-relative
    // times get shifted onto movie-time (the recording's audio leading-gap).
    audioOffset: (video, source) async {
      try {
        final probe = await ffmpegProbe(path: video);
        return captionAudioOffsetMicros(source, probe.audioStreams);
      } catch (_) {
        return 0;
      }
    },
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

  // Captured eagerly in initState (NOT a lazy `late final = ref.read(...)`
  // initializer — that would only run on first access, and if dispose() is
  // the first access, ref.read would throw; see below). ref.read throws
  // ("Cannot use ref after the widget was disposed") if called from
  // dispose() — Flutter's StatefulElement.unmount() marks the element
  // defunct via super.unmount() *before* invoking State.dispose(), so by the
  // time our dispose() body runs, ref is already unusable. crumbStoreProvider
  // is a plain Provider<PersistentCrumbStore> overridden once at app start
  // (not autoDispose, not scoped to this widget), so caching the instance in
  // initState is safe for the widget's whole lifetime.
  late final PersistentCrumbStore _crumbStore;

  @override
  void initState() {
    super.initState();
    _crumbStore = ref.read(crumbStoreProvider);
  }

  @override
  void dispose() {
    // Covers the "navigate away mid-run" gap the terminal-status listener
    // below can't: CaptionGenerationController is autoDispose and its
    // _setState only writes `if (mounted)`, so if this tab closes while
    // generate() is still running (a real case — whisper on a long
    // recording runs for minutes), the controller never reaches a terminal
    // status after this widget is gone, the ref.listen clear never fires,
    // and the activity would otherwise stay 'transcribe' for the rest of
    // the session — misattributing a later, unrelated crash.
    _crumbStore.setActivity(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(captionGenerationControllerProvider);
    final sourcesAsync =
        ref.watch(captionAudioSourcesProvider(widget.videoPath));
    final hasCaptions = ref.watch(
      editorProjectControllerProvider.select((s) => s.captions.isNotEmpty),
    );

    // The generate() run covers two native handoffs (ffmpeg audio extract,
    // whisper-cli transcribe) with no provider access at that depth — clear
    // the activity here, at the nearest boundary, once the run reaches a
    // terminal status.
    ref.listen<CaptionGenerationStatus>(captionGenerationControllerProvider,
        (prev, next) {
      if (next is CaptionDone || next is CaptionError || next is CaptionCancelled) {
        _crumbStore.setActivity(null);
      }
    });

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
                status is! CaptionError &&
                status is! CaptionCancelled;
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
                // While a run is in flight the button becomes the cancel
                // affordance — whisper on a long recording runs for
                // minutes and used to be unkillable.
                FilledButton.icon(
                  onPressed: busy
                      ? () => ref
                          .read(captionGenerationControllerProvider.notifier)
                          .cancel()
                      : () {
                          // Right before the native handoffs inside
                          // generate() (ffmpeg extract, then whisper-cli).
                          _crumbStore.setActivity({'op': 'transcribe'});
                          _crumbStore.flushNow();
                          ref
                              .read(captionGenerationControllerProvider.notifier)
                              .generate(
                                videoPath: widget.videoPath,
                                source: selected,
                              );
                        },
                  icon: Icon(
                    busy ? Icons.stop : Icons.closed_caption,
                    size: 18,
                  ),
                  label: Text(busy
                      ? 'Cancel'
                      : hasCaptions
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
      CaptionCancelled() => ('Cancelled.', false),
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
