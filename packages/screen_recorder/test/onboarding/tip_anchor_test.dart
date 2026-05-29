import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tip_anchor.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TipsController> _freshController() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  return c;
}

void main() {
  testWidgets('first mount fires the overlay; Got it dismisses + marks seen',
      (tester) async {
    final c = await _freshController();
    await tester.pumpWidget(ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: TipAnchor(
              tipId: TipId.barModePicker,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(); // post-frame callback
    await tester.pumpAndSettle();

    expect(find.text('Got it'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    expect(find.text('Got it'), findsNothing);
    expect(c.shouldShow(TipId.barModePicker), isFalse);
  });

  testWidgets('already-seen anchor never fires', (tester) async {
    final c = await _freshController();
    await c.markSeen(TipId.barModePicker);
    await tester.pumpWidget(ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: TipAnchor(
              tipId: TipId.barModePicker,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsNothing);
  });

  testWidgets('anchor inside Visibility(visible:false) does not fire until revealed',
      (tester) async {
    final c = await _freshController();

    // Use StatefulBuilder so we can toggle `show` mid-test.
    await tester.pumpWidget(ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Center(
              child: Visibility(
                // maintainState: false (default) fully unmounts the subtree
                // when invisible, so TipAnchor's initState never runs.
                visible: false,
                child: TipAnchor(
                  tipId: TipId.barModePicker,
                  child: const SizedBox(width: 80, height: 40),
                ),
              ),
            ),
            floatingActionButton: FloatingActionButton(
              key: const Key('reveal'),
              onPressed: () => setState(() {}),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pumpAndSettle();

    // Tip should NOT have fired while the anchor is not in the tree.
    expect(find.text('Got it'), findsNothing);

    // Now rebuild with the anchor visible by replacing the widget tree.
    await tester.pumpWidget(ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: TipAnchor(
              tipId: TipId.barModePicker,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(); // post-frame callback
    await tester.pumpAndSettle();

    // Now it fires.
    expect(find.text('Got it'), findsOneWidget);
  });
}
