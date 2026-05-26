import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/audio_tab.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

void main() {
  Widget host(List<AudioStreamInfo> streams) => ProviderScope(
        overrides: [
          recordingAudioStreamsProvider.overrideWith((ref) => streams),
        ],
        child: const MaterialApp(home: Scaffold(body: AudioTab())),
      );

  testWidgets('shows Microphone + System rows for a mic+system recording',
      (t) async {
    await t.pumpWidget(host(const [
      AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
      AudioStreamInfo(index: 1, channels: 2, codecName: 'aac'),
    ]));
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('System audio'), findsOneWidget);
  });

  testWidgets('shows only Microphone for a mic-only recording', (t) async {
    await t.pumpWidget(host(const [
      AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
    ]));
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('System audio'), findsNothing);
  });

  testWidgets('shows empty state when there is no recorded audio', (t) async {
    await t.pumpWidget(host(const []));
    expect(find.text('No audio in this recording'), findsOneWidget);
  });
}
