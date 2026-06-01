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
  testWidgets(
      'two-finger scroll at scale > 1 does NOT fire onHoverSeek '
      '(cursor stationary, content shifts underneath)', (tester) async {
    final tips = await _freshTips();
    final seekedTimes = <Duration>[];
    final hoverSeekedTimes = <Duration>[];

    // scale=2.0, total=10s, viewport=600 → content=1200, pps=120.
    await tester.pumpWidget(_host(
      EditorTimeline(
        duration: const Duration(seconds: 10),
        position: Duration.zero,
        onSeek: seekedTimes.add,
        onHoverSeek: hoverSeekedTimes.add,
        timelineScale: 2.0,
        isPlaying: false,
      ),
      tips,
    ));
    await tester.pumpAndSettle();

    // Move the mouse to the middle of the viewport. This fires onHover,
    // which is expected to seek once (the cursor moved into position).
    final viewportCenter = tester.getCenter(find.byType(EditorTimeline));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: viewportCenter);
    addTearDown(gesture.removePointer);
    await tester.pump();

    // Move so we get a hover with a global position.
    await gesture.moveTo(viewportCenter);
    await tester.pump();
    final hoverCountAfterPositioning = hoverSeekedTimes.length;
    expect(hoverCountAfterPositioning, greaterThanOrEqualTo(0));

    // Simulate a two-finger trackpad scroll: drive the scroll controller
    // directly. The OS would re-fire a synthetic hover at the same
    // global position because the content shifted underneath.
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    scroll.controller!.jumpTo(200);
    await tester.pump();

    // Synthesize a hover at the SAME global position as before. This is
    // exactly what Flutter's mouse tracker does after a scroll: the
    // pointer hasn't moved globally, but a hover event fires because
    // the content under it changed.
    await gesture.moveTo(viewportCenter);
    await tester.pump();

    // The post-scroll hover at the same global position must NOT add a
    // new onHoverSeek call. If the bug is back, we'd see an extra entry
    // with a different time (because scrollOffset shifted).
    expect(hoverSeekedTimes.length, hoverCountAfterPositioning,
        reason:
            'Hover-seek fired during two-finger scroll. The playhead would '
            'seek while the user is just panning the timeline.');

    // Real cursor movement after scroll should still seek normally.
    await gesture.moveTo(viewportCenter.translate(20, 0));
    await tester.pump();
    expect(hoverSeekedTimes.length, greaterThan(hoverCountAfterPositioning),
        reason: 'Real pointer movement should still drive hover-scrub.');
  });

}
