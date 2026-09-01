import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/onboarding/pages/features_page.dart';

Future<void> _pump(WidgetTester tester, {required VoidCallback onNext}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: FeaturesPage(onNext: onNext)),
  ));
  // One frame: the video widget kicks off async asset init that throws in the
  // headless test (no platform plugin) and falls back to the poster — we just
  // need the page chrome, so a single pump is enough. Avoid pumpAndSettle: the
  // poster's loading spinner animates forever and would hang it.
  await tester.pump();
}

Future<void> _teardown(WidgetTester tester) async {
  // Replace the tree so the tab strip's State.dispose() disposes its
  // auto-advance AnimationController; otherwise the test fails with an active
  // ticker still running at the end.
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('renders the first feature and a Continue button',
      (tester) async {
    await _pump(tester, onNext: () {});
    expect(find.text('Automatic zoom'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('Continue invokes onNext', (tester) async {
    var tapped = 0;
    await _pump(tester, onNext: () => tapped++);
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    expect(tapped, 1);
    await _teardown(tester);
  });

  testWidgets('tapping a tab switches the highlighted feature', (tester) async {
    await _pump(tester, onNext: () {});
    expect(find.text('Automatic zoom'), findsOneWidget);

    // Tab labels are short names; 'Keystrokes' is the third feature. (Its
    // detail title is 'Keystroke overlays', so the tab text is unambiguous.)
    await tester.tap(find.text('Keystrokes'));
    await tester.pump(const Duration(milliseconds: 300));

    // The keystrokes beat is now the highlighted feature. (The outgoing title
    // may still be mid-fade in the AnimatedSwitcher, so we assert the new one
    // appeared rather than that the old one is already gone.)
    expect(find.text('Keystroke overlays'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('auto-advances to the next feature after the dwell',
      (tester) async {
    await _pump(tester, onNext: () {});
    expect(find.text('Automatic zoom'), findsOneWidget);

    // Let the fill/dwell controller (5.4s) complete, then the caption switch.
    await tester.pump(const Duration(milliseconds: 5500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Polished cursor'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('inactive page does not auto-advance', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FeaturesPage(onNext: _noop, active: false)),
    ));
    await tester.pump();
    expect(find.text('Automatic zoom'), findsOneWidget);

    // With the page inactive the trace is frozen, so no advance happens.
    await tester.pump(const Duration(milliseconds: 6000));

    expect(find.text('Automatic zoom'), findsOneWidget);
    await _teardown(tester);
  });
}

void _noop() {}
