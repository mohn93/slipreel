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
  testWidgets('scale 1→2 with anchor=playhead keeps playhead viewport-x', (
    tester,
  ) async {
    final tips = await _freshTips();
    var consumed = 0;
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 5)),
          onSeek: (_) {},
          timelineScale: 1.0,
          onAnchorConsumed: () => consumed++,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // At scale=1, pps=56, so 5s sits at content-x=280 and viewport-x=300
    // including the 20px inner inset. At scale=2, content-x=560, so the
    // same viewport-x is preserved by offset = 20 + 560 - 300 = 280.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 5)),
          onSeek: (_) {},
          timelineScale: 2.0,
          pendingScaleAnchor: const Duration(seconds: 5),
          onAnchorConsumed: () => consumed++,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), closeTo(280.0, 1.0));
    expect(consumed, 1, reason: 'anchor must be consumed exactly once');
  });

  testWidgets('different anchor (e.g. 7s) preserves the anchor, not playhead', (
    tester,
  ) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 5)),
          onSeek: (_) {},
          timelineScale: 1.0,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Scale to 2.0 with anchor at 7s.
    // At scale=1: 7s content-x = 392, viewport-x = 412.
    // At scale=2: content-x of 7s = 784. To keep viewport-x at 412,
    // offset = 20 + 784 - 412 = 392.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 5)),
          onSeek: (_) {},
          timelineScale: 2.0,
          pendingScaleAnchor: const Duration(seconds: 7),
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), closeTo(392.0, 1.0));
  });

  testWidgets('scroll offset clamps at 0 when computed offset is negative', (
    tester,
  ) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 1)),
          onSeek: (_) {},
          timelineScale: 1.0,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Anchor at 1s, scale to 2.0. content-x of 1s = 120.
    // viewport-x before = 60. New offset = 120 - 60 = 60 → positive, clamps fine.
    // Use anchor=0 to force clamp: content-x = 0, viewport-x = 0 → offset = 0.
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(const Duration(seconds: 1)),
          onSeek: (_) {},
          timelineScale: 2.0,
          pendingScaleAnchor: Duration.zero,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), 0.0);
  });
}
