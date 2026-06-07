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
  testWidgets('two-finger pinch fires onPinchScale with cursor anchor',
      (tester) async {
    final tips = await _freshTips();
    double? gotScale;
    Duration? gotAnchor;
    await tester.pumpWidget(_host(
      EditorTimeline(
        duration: const Duration(seconds: 10),
        position: ValueNotifier<Duration>(Duration.zero),
        onSeek: (_) {},
        timelineScale: 1.0,
        onPinchScale: (s, a) {
          gotScale = s;
          gotAnchor = a;
        },
      ),
      tips,
    ));
    await tester.pumpAndSettle();

    // Synthesize a two-finger pinch centered at the timeline's mid (~5s),
    // moving both pointers outward to scale > 1.
    final center = tester.getCenter(find.byType(EditorTimeline));
    final p1 = await tester.startGesture(center - const Offset(20, 0));
    final p2 = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await p1.moveBy(const Offset(-20, 0));
    await p2.moveBy(const Offset(20, 0));
    await tester.pump();
    await p1.up();
    await p2.up();
    await tester.pumpAndSettle();

    expect(gotScale, isNotNull);
    expect(gotScale, greaterThan(1.0));
    expect(gotAnchor, isNotNull);
    // Anchor should be near the time corresponding to center-x (~5s).
    expect(gotAnchor!.inMilliseconds, closeTo(5000, 1500));
  });

  testWidgets('single-finger drag does NOT fire onPinchScale',
      (tester) async {
    final tips = await _freshTips();
    var fires = 0;
    await tester.pumpWidget(_host(
      EditorTimeline(
        duration: const Duration(seconds: 10),
        position: ValueNotifier<Duration>(Duration.zero),
        onSeek: (_) {},
        timelineScale: 1.0,
        onPinchScale: (_, __) => fires++,
      ),
      tips,
    ));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(EditorTimeline));
    await tester.dragFrom(center, const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(fires, 0);
  });
}
