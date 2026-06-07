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

double _scrollOffset(WidgetTester tester) {
  final scroll = tester.widget<SingleChildScrollView>(
    find.byType(SingleChildScrollView),
  );
  return scroll.controller!.offset;
}

void main() {
  testWidgets('playhead crossing 80% viewport while playing triggers snap', (
    tester,
  ) async {
    final tips = await _freshTips();
    // scale=4.0, total=10s, viewport=600 → content=2400, pps=240.
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

    // Advance position to 1.9s -> content-x = 425.6. With the 20px inner
    // left inset and offset=0, viewport-x = 445.6. Still below
    // 0.8 * 600 = 480, so no snap.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(milliseconds: 1900)),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester), 0.0);

    // Advance to 2.5s → content-x = 560 → viewport-x = 580 > 480 → snap.
    // Target offset = 20px inset + 560 - 0.2 * 600 = 460.
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
    expect(_scrollOffset(tester), closeTo(460.0, 1.0));
  });

  testWidgets('no snap when isPlaying=false', (tester) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: false,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(
            const Duration(seconds: 8),
          ), // way past 80%
          onSeek: (_) {},
          timelineScale: 4.0,
          isPlaying: false,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester), 0.0);
  });

  testWidgets('no snap at scale==1.0', (tester) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 1.0,
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
          position: ValueNotifier<Duration>(const Duration(seconds: 9)),
          onSeek: (_) {},
          timelineScale: 1.0,
          isPlaying: true,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _scrollOffset(tester),
      0.0,
      reason: 'NeverScrollable physics — offset stays 0',
    );
  });
}
