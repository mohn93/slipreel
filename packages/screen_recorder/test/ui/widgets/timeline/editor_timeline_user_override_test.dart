import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TipsController> _freshTips() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  return c;
}

Widget _host(Widget child, TipsController tips, {double width = 600}) =>
    ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => tips)],
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SizedBox(width: width, height: 220, child: child),
        ),
      ),
    );

ScrollController _scrollController(WidgetTester tester) {
  final scroll = tester.widget<SingleChildScrollView>(
    find.byType(SingleChildScrollView),
  );
  return scroll.controller!;
}

double _scrollOffset(WidgetTester tester) => _scrollController(tester).offset;

void main() {
  testWidgets('auto-follow snaps when no user scroll has happened', (
    tester,
  ) async {
    // Sanity check matching the existing G4 test: with no user scroll,
    // playhead crossing 80% triggers a snap.
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(milliseconds: 2500)),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();
    // Snap target: 20px inner inset + content-x 560 - 120 = 460.
    expect(_scrollOffset(tester), closeTo(460.0, 1.0));
  });

  testWidgets(
    'user scroll during playback disables auto-follow for the rest of the session',
    (tester) async {
      final tips = await _freshTips();
      await tester.pumpWidget(
        _host(
          EditorTimeline(
            duration: const Duration(seconds: 10),
            position: ValueNotifier<Duration>(Duration.zero),
            onSeek: (_) {},
            timelineScale: 4.0,
            isPlaying: true,
          ),
          tips,
        ),
      );
      await tester.pumpAndSettle();

      // Simulate a user-initiated scroll to 50px. The scroll listener
      // should set _userOverrodeScroll = true because the programmatic
      // flag is false.
      _scrollController(tester).jumpTo(50.0);
      await tester.pump();
      expect(_scrollOffset(tester), 50.0);

      // Now advance the playhead well past the 80% mark. Without the
      // override, auto-follow would snap to ~460. With the override, the
      // offset should stay at 50.
      await tester.pumpWidget(
        _host(
          EditorTimeline(
            duration: const Duration(seconds: 10),
            position: ValueNotifier<Duration>(
              const Duration(milliseconds: 2500),
            ),
            onSeek: (_) {},
            timelineScale: 4.0,
            isPlaying: true,
          ),
          tips,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _scrollOffset(tester),
        50.0,
        reason: 'user-scroll override must suppress auto-follow',
      );

      // Further playhead advances must also be ignored.
      await tester.pumpWidget(
        _host(
          EditorTimeline(
            duration: const Duration(seconds: 10),
            position: ValueNotifier<Duration>(const Duration(seconds: 5)),
            onSeek: (_) {},
            timelineScale: 4.0,
            isPlaying: true,
          ),
          tips,
        ),
      );
      await tester.pumpAndSettle();
      expect(_scrollOffset(tester), 50.0);
    },
  );

  testWidgets('pause + resume re-enables auto-follow', (tester) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // User scrolls during playback → override engaged.
    _scrollController(tester).jumpTo(50.0);
    await tester.pump();

    // Verify auto-follow is suppressed.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(milliseconds: 2500)),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester), 50.0);

    // Pause.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(milliseconds: 2500)),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: false,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Resume — this isPlaying false→true transition should reset the
    // override. Also reset the playhead so we have a clean run-up.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Now advance past 80% — auto-follow should snap again.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(milliseconds: 2500)),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _scrollOffset(tester),
      closeTo(460.0, 1.0),
      reason: 'override should reset on play→pause→play',
    );
  });

  testWidgets('anchor-preserve scroll does NOT count as user override', (
    tester,
  ) async {
    final tips = await _freshTips();
    // scale=1.0 → content fits viewport; physics is NeverScrollable so
    // no scroll listener fire is even possible at this stage.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 5)),
          onSeek: (_) {},
          timelineScale: 1.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Change scale to 2.0 with anchor=5s. _applyScale runs its own
    // jumpTo (to preserve the anchor's viewport-x). That jumpTo must
    // NOT flip _userOverrodeScroll, because we wrap it with the
    // programmatic-scroll flag.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 5)),
          onSeek: (_) {},
          timelineScale: 2.0,
          pendingScaleAnchor: const Duration(seconds: 5),
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // At scale=1, pps=56, so 5s sits at content-x=280 and viewport-x=300
    // including the 20px inner inset. At scale=2, content-x=560, so new
    // offset = 20 + 560 - 300 = 280.
    expect(_scrollOffset(tester), closeTo(280.0, 1.0));

    // Now advance the playhead well past the 80% mark relative to the
    // new offset. Playhead 9s @ scale=2 -> content-x = 1008 -> viewport-x
    // (from offset 280) = 748 -> well > 0.8 * 600 = 480 -> must snap.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 9)),
          onSeek: (_) {},
          timelineScale: 2.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();
    // Target offset = inner inset + playheadContentX - 0.2*viewport
    // = 20 + 1008 - 120 = 908. But clamped to maxOffset
    // = 20 + 1120 + 20 - 600 = 560.
    expect(
      _scrollOffset(tester),
      closeTo(560.0, 1.0),
      reason: 'anchor-preserve jumpTo must not flip the user-override flag',
    );
  });
}
