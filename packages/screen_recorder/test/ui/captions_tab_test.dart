// packages/screen_recorder/test/ui/captions_tab_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';
import 'package:screen_recorder/diagnostics/persistent_crumb_store.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';
import 'package:screen_recorder/state/caption_generation_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/captions_tab.dart';

/// A caption controller wired to trivial fakes so the widget test never
/// touches the real WhisperModelStore / extractor / transcriber. It stays
/// in [CaptionIdle] unless `generate` is invoked, which the test doesn't do.
CaptionGenerationController _fakeController() => CaptionGenerationController(
      editor: EditorProjectController(),
      ensureModel: (_) async => '/fake/model.bin',
      extractAudio: (_, __, ___) async => '/fake/audio.wav',
      transcribe: (_, __, ___, ____) async => const [],
      audioOffset: (_, __) async => 0,
    );

/// A disabled store: setActivity/flushNow are safe no-ops (enabled: false
/// short-circuits writeIfDirty before any file I/O), so the widget's
/// initState/dispose reads of crumbStoreProvider (Task 7: activity context
/// around the transcribe handoff) don't need a real session.json on disk.
PersistentCrumbStore _fakeCrumbStore() => PersistentCrumbStore(
      path: '/unused/session.json',
      sessionId: 'test-session',
      breadcrumbs: Breadcrumbs(),
      scrubber: PiiScrubber(homeDir: '/Users/test'),
      enabled: false,
    );

/// A crumb store that records every setActivity call so the test can assert
/// the transcribe-activity handoff and the dispose-time clear. Enabled so it
/// behaves like production; pointed at a temp file so flushNow() is real but
/// harmless.
class _SpyCrumbStore extends PersistentCrumbStore {
  _SpyCrumbStore(String path)
      : super(
          path: path,
          sessionId: 'test-session',
          breadcrumbs: Breadcrumbs(),
          scrubber: PiiScrubber(homeDir: '/Users/test'),
          enabled: true,
        );
  final List<Map<String, Object?>?> activityCalls = [];

  @override
  void setActivity(Map<String, Object?>? activity) {
    activityCalls.add(activity);
    super.setActivity(activity);
  }
}

void main() {
  // T2: the transcribe handoff sets activity, and disposing the tab mid-run
  // clears it — the "navigate away while whisper is still running" gap.
  testWidgets(
      'sets transcribe activity on Generate and clears it when the tab is '
      'disposed mid-run', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('captions_tab_spy');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final spy = _SpyCrumbStore('${tmp.path}/session.json');

    // A controller whose transcribe never completes, so the run stays busy:
    // this isolates dispose()'s clear from the terminal-status listener's.
    final blocked = Completer<List<CaptionSegment>>();
    addTearDown(() {
      if (!blocked.isCompleted) blocked.complete(const []);
    });
    final controller = CaptionGenerationController(
      editor: EditorProjectController(),
      ensureModel: (_) async => '/fake/model.bin',
      extractAudio: (_, __, ___) async => '/fake/audio.wav',
      transcribe: (_, __, ___, ____) => blocked.future,
      audioOffset: (_, __) async => 0,
    );

    final overrides = [
      captionAudioSourcesProvider('/v.mov').overrideWith(
        (ref) async => const [CaptionAudioSource.mic],
      ),
      captionGenerationControllerProvider.overrideWith((ref) => controller),
      crumbStoreProvider.overrideWithValue(spy),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: const MaterialApp(
          home: Scaffold(body: CaptionsTab(videoPath: '/v.mov')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Generate captions'));
    await tester.pump(); // let the tap handler run (sets activity)
    await tester.pump(const Duration(milliseconds: 10));

    expect(spy.activityCalls, contains(equals({'op': 'transcribe'})));

    // Rebuild the tree WITHOUT the tab: its State.dispose() runs while the
    // run is still in flight.
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();

    expect(spy.activityCalls.last, isNull);
  });

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
          crumbStoreProvider.overrideWithValue(_fakeCrumbStore()),
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
