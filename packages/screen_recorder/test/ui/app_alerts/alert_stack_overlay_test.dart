// Regression test for m8: an alert that arrives while the deck is hover-
// expanded must have its auto-dismiss timer paused too — otherwise it vanishes
// out from under the cursor while the user is reading the deck.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/app_alerts/alert_stack_overlay.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

void main() {
  AlertEntry entry(String msg) => AlertEntry(
        type: AlertType.info,
        message: msg,
        duration: const Duration(seconds: 5),
      );

  testWidgets('a new alert arriving while hover-expanded is not dismissed '
      'under the cursor', (tester) async {
    final controller = AppAlertsController();

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AlertStackOverlay(controller: controller))),
    );

    controller.pushEntry(entry('first'));
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    // Let the enter animation (slide+fade) finish so the pill is in place.
    await tester.pumpAndSettle();

    // Hover over the deck (clicking a pill would dismiss it; hover is the
    // expand affordance). Anchor at a fixed top-center point that stays over
    // the front pill in both the collapsed and expanded layouts, so the
    // pointer never drifts off and triggers an unwanted onExit.
    const deckPoint = Offset(400, 40);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(deckPoint);
    await tester.pumpAndSettle(); // expand animation settles

    // A second alert arrives WHILE the cursor is parked on the deck.
    controller.pushEntry(entry('second'));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    // Past both durations — neither should auto-dismiss while hovered.
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('first'), findsOneWidget,
        reason: 'paused on hover at expand time');
    expect(find.text('second'), findsOneWidget,
        reason: 'm8: a late arrival must be paused while expanded too');

    // Leave the deck → timers resume → both dismiss after their duration.
    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsNothing);
  });
}
