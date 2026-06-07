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
          body: SizedBox(width: width, height: 220, child: child),
        ),
      ),
    );

void main() {
  testWidgets('at scale=1.0, content width equals viewport width', (
    tester,
  ) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 1.0,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    final scrollFinder = find.byType(SingleChildScrollView);
    expect(scrollFinder, findsOneWidget);

    final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
    // Edge-pad now breathes 0→200 during trim drags, so the scroll
    // physics stays scrollable (NeverScrollable would block the
    // pad-driven jumpTo lockstep). The behavioral contract — drag at
    // scale=1 doesn't shift content — is covered by the drag test
    // below: maxScrollExtent is 0 at idle (pad=0, content=viewport),
    // so there is nowhere to scroll.
    expect(scroll.physics, isA<BouncingScrollPhysics>());

    // The first SizedBox inside the scroll view is the scroll canvas.
    // At 1x, the time axis is viewport minus the two 20px inner edge
    // insets, so the canvas still fits the viewport exactly.
    final scrollCanvas = tester.widget<SizedBox>(
      find.descendant(of: scrollFinder, matching: find.byType(SizedBox)).first,
    );
    expect(scrollCanvas.width, closeTo(600.0, 0.5));
  });

  testWidgets('at scale=2.0, content width is 2× viewport width', (
    tester,
  ) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 2.0,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    final scrollFinder = find.byType(SingleChildScrollView);
    final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
    // Lock the implementation choice — the timeline uses iOS-style
    // bounce/momentum physics, not just "anything other than
    // NeverScrollable".
    expect(scroll.physics, isA<BouncingScrollPhysics>());

    // Direct scroll canvas is scaled time-axis width plus 20px inner
    // edge inset on both sides: (600 - 40) * 2 + 40 = 1160.
    final scrollCanvas = tester.widget<SizedBox>(
      find.descendant(of: scrollFinder, matching: find.byType(SizedBox)).first,
    );
    expect(scrollCanvas.width, closeTo(1160.0, 0.5));
  });

  testWidgets('at scale=1.0, horizontal drag does not change scroll offset', (
    tester,
  ) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 1.0,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Drag inside the scrollable. At 1x the scroll canvas fits the
    // viewport exactly, with the edge insets inside that width.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll.controller!.offset, 0.0);
  });

  testWidgets('trackpad pan scrolls and keeps momentum after release', (
    tester,
  ) async {
    final tips = await _freshTips();
    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (_) {},
          timelineScale: 2.0,
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(EditorTimeline));
    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    const device = 17;

    tester.binding.handlePointerEvent(
      PointerPanZoomStartEvent(
        device: device,
        position: center,
        timeStamp: Duration.zero,
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    tester.binding.handlePointerEvent(
      PointerPanZoomUpdateEvent(
        device: device,
        position: center,
        pan: const Offset(-40, 0),
        panDelta: const Offset(-40, 0),
        scale: 1.0,
        timeStamp: const Duration(milliseconds: 16),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    tester.binding.handlePointerEvent(
      PointerPanZoomUpdateEvent(
        device: device,
        position: center,
        pan: const Offset(-100, 0),
        panDelta: const Offset(-60, 0),
        scale: 1.0,
        timeStamp: const Duration(milliseconds: 32),
      ),
    );
    await tester.pump();

    final offsetAfterPan = scroll.controller!.offset;
    expect(offsetAfterPan, greaterThan(80.0));

    tester.binding.handlePointerEvent(
      PointerPanZoomEndEvent(
        device: device,
        position: center,
        timeStamp: const Duration(milliseconds: 48),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(scroll.controller!.offset, greaterThan(offsetAfterPan));
  });
}
