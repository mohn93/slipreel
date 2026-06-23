// packages/screen_recorder/test/ui/captions_tab_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/caption_generation_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/captions_tab.dart';

/// A caption controller wired to trivial fakes so the widget test never
/// touches the real WhisperModelStore / extractor / transcriber. It stays
/// in [CaptionIdle] unless `generate` is invoked, which the test doesn't do.
CaptionGenerationController _fakeController() => CaptionGenerationController(
      editor: EditorProjectController(),
      ensureModel: (_) async => '/fake/model.bin',
      extractAudio: (_, __) async => '/fake/audio.wav',
      transcribe: (_, __, ___) async => const [],
      audioOffset: (_, __) async => 0,
    );

void main() {
  testWidgets('shows source chips and a Generate button', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          captionAudioSourcesProvider('/v.mov').overrideWith(
            (ref) async => const [
              CaptionAudioSource.mic,
              CaptionAudioSource.mixed,
            ],
          ),
          captionGenerationControllerProvider
              .overrideWith((ref) => _fakeController()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: CaptionsTab(videoPath: '/v.mov')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Generate captions'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
  });
}
