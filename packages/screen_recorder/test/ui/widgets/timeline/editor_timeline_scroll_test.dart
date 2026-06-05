import 'package:flutter/gestures.dart';
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
          body: SizedBox(width: width, height: 200, child: child),
        ),
      ),
    );

void main() {
  testWidgets('at scale=1.0, content width equals viewport width',
      (tester) async {
    final tips = await _freshTips();
    await tester.pumpWidget(_host(
      EditorTimeline(
        duration: const Duration(seconds: 10),
        position: ValueNotifier<Duration>(Duration.zero),
        onSeek: (_) {},
        timelineScale: 1.0,
      ),
      tips,
    ));
    await tester.pumpAndSettle();

    final scrollFinder = find.byType(SingleChildScrollView);
    expect(scrollFinder, findsOneWidget);

    final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
    // Edge-pad now breathes 0→200 during trim drags, so the scroll
    // physics is always Clamping (NeverScrollable would block the
    // pad-driven jumpTo lockstep). The behavioral contract — drag at
    // scale=1 doesn't shift content — is covered by the drag test
    // below: maxScrollExtent is 0 at idle (pad=0, content=viewport),
    // so Clamping has nowhere to scroll.
    expect(scroll.physics, isA<ClampingScrollPhysics>());

    // The DIRECT child of the SingleChildScrollView is our content
    // SizedBox(width: contentWidth, ...). Targeting `.first` (instead of
    // scanning all descendants for "any 600-wide box") guards against
    // false positives — e.g. the inner Scaffold's body or an unrelated
    // descendant that happens to share the viewport width.
    final contentSized = tester.widget<SizedBox>(
      find.descendant(of: scrollFinder, matching: find.byType(SizedBox)).first,
    );
    expect(contentSized.width, closeTo(600.0, 0.5));
  });

  testWidgets('at scale=2.0, content width is 2× viewport width',
      (tester) async {
    final tips = await _freshTips();
    await tester.pumpWidget(_host(
      EditorTimeline(
        duration: const Duration(seconds: 10),
        position: ValueNotifier<Duration>(Duration.zero),
        onSeek: (_) {},
        timelineScale: 2.0,
      ),
      tips,
    ));
    await tester.pumpAndSettle();

    final scrollFinder = find.byType(SingleChildScrollView);
    final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
    // Lock the implementation choice — at scale>1 we want clamping
    // physics, not just "anything other than NeverScrollable".
    expect(scroll.physics, isA<ClampingScrollPhysics>());

    // Direct child of the scroll view is the content SizedBox.
    final contentSized = tester.widget<SizedBox>(
      find.descendant(of: scrollFinder, matching: find.byType(SizedBox)).first,
    );
    expect(contentSized.width, closeTo(1200.0, 0.5));
  });

  testWidgets('at scale=1.0, horizontal drag does not change scroll offset',
      (tester) async {
    final tips = await _freshTips();
    await tester.pumpWidget(_host(
      EditorTimeline(
        duration: const Duration(seconds: 10),
        position: ValueNotifier<Duration>(Duration.zero),
        onSeek: (_) {},
        timelineScale: 1.0,
      ),
      tips,
    ));
    await tester.pumpAndSettle();

    // Drag inside the scrollable. NeverScrollable means offset stays 0.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    final scroll =
        tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.controller!.offset, 0.0);
  });
}
