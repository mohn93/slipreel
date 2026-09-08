import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/audio_tab.dart';
import 'package:screen_recorder/ui/widgets/timeline/music_lane.dart';
import 'package:slipreel_engine/audio/music_track.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  const music = MusicTrack(
    path: '/missing.wav',
    name: 'My music',
    sourceDuration: 10,
  );
  testWidgets(
    'music controls change project state, removal and missing-file feedback',
    (t) async {
      final controller = EditorProjectController(
        initial: EditorProjectState.defaults().copyWith(
          timeline: Timeline(
            music: music,
            clips: [
              ClipSlice(
                cutStart: Duration.zero,
                cutEnd: const Duration(seconds: 20),
              ),
            ],
          ),
        ),
      );
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            editorProjectControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [AppPalette.midnight]),
            home: const Scaffold(body: SizedBox(width: 340, child: AudioTab())),
          ),
        ),
      );
      expect(find.textContaining('Audio file is missing'), findsOneWidget);
      await t.scrollUntilVisible(find.byIcon(Icons.volume_up), 100);
      await t.tap(find.byIcon(Icons.volume_up));
      await t.pump();
      expect(controller.current.timeline.music!.muted, isTrue);
      await t.scrollUntilVisible(find.text('Loop to video end'), 100);
      await t.tap(find.text('Loop to video end'));
      await t.pump();
      expect(controller.current.timeline.music!.loop, isFalse);
      await t.scrollUntilVisible(find.text('Lower music during speech'), 100);
      await t.tap(find.text('Lower music during speech'));
      await t.pump();
      expect(controller.current.timeline.music!.duck, isTrue);
      await t.scrollUntilVisible(find.byTooltip('Remove music'), -100);
      await t.tap(find.byTooltip('Remove music'));
      await t.pump();
      expect(controller.current.timeline.music, isNull);
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Add background audio'), -100);
      expect(find.text('Add background audio'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'music lane selects its inspector, drags, and tiny tracks do not overflow',
    (t) async {
      var selected = false;
      final controller = EditorProjectController(
        initial: EditorProjectState.defaults().copyWith(
          timeline: Timeline(music: music),
        ),
      );
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            editorProjectControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 36,
                child: MusicLane(
                  pixelsPerSecond: 20,
                  duration: 20,
                  onSelected: () => selected = true,
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.textContaining('My music'));
      await t.pump();
      expect(selected, isTrue);
      expect(find.byType(Dialog), findsNothing);
      await t.drag(find.textContaining('My music'), const Offset(80, 0));
      await t.pump();
      expect(controller.current.timeline.music!.start, greaterThan(2));
      controller.setMusic(music.copyWith(start: 19.99));
      await t.pump();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('music lane edge handles resize start and end', (t) async {
    final controller = EditorProjectController(
      initial: EditorProjectState.defaults().copyWith(
        timeline: Timeline(music: music),
      ),
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          editorProjectControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 36,
              // 20s at 20px/s fills the full 400px width, so the right handle
              // sits at the far edge and the left handle at the near edge.
              child: MusicLane(pixelsPerSecond: 20, duration: 20),
            ),
          ),
        ),
      ),
    );
    // Drag the right edge 100px (5s) inward: a looping bed that used to fill
    // to the video end now stops early via an explicit end override.
    await t.dragFrom(const Offset(393, 18), const Offset(-100, 0));
    await t.pump();
    final afterRight = controller.current.timeline.music!;
    // Right edge moved ~4-5s inward (a little is eaten by drag touch-slop):
    // the bed now stores an explicit end well short of the 20s video.
    expect(afterRight.endOverride, isNotNull);
    expect(afterRight.endOverride, inInclusiveRange(13, 17));
    expect(afterRight.length(20), closeTo(afterRight.endOverride!, 0.01));
    // Drag the left edge inward: start advances off zero, right edge stays put.
    await t.dragFrom(const Offset(7, 18), const Offset(60, 0));
    await t.pump();
    final afterLeft = controller.current.timeline.music!;
    expect(afterLeft.start, greaterThan(1));
    expect(afterLeft.endOverride, closeTo(afterRight.endOverride!, 0.5));
    expect(t.takeException(), isNull);
  });
}
