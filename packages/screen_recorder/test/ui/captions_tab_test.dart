// packages/screen_recorder/test/ui/captions_tab_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:screen_recorder/state/caption_generation_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/captions_tab.dart';

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
