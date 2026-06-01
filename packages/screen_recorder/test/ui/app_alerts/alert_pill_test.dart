import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/app_alerts/alert_pill.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

void main() {
  Future<void> pump(WidgetTester tester, AlertEntry entry, {
    VoidCallback? onDismiss,
    VoidCallback? onHoverEnter,
    VoidCallback? onHoverExit,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AlertPill(
            entry: entry,
            onDismiss: onDismiss ?? () {},
            onHoverEnter: onHoverEnter ?? () {},
            onHoverExit: onHoverExit ?? () {},
          ),
        ),
      ),
    ));
  }

  testWidgets('renders the message text', (tester) async {
    await pump(
      tester,
      AlertEntry(
        type: AlertType.info,
        message: 'hello world',
        duration: Duration.zero,
      ),
    );
    expect(find.text('hello world'), findsOneWidget);
  });

  testWidgets('renders the type icon', (tester) async {
    await pump(
      tester,
      AlertEntry(
        type: AlertType.success,
        message: 'ok',
        duration: Duration.zero,
      ),
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('tap on the pill body fires onDismiss', (tester) async {
    var dismissed = 0;
    await pump(
      tester,
      AlertEntry(
        type: AlertType.info,
        message: 'click me',
        duration: Duration.zero,
      ),
      onDismiss: () => dismissed++,
    );
    await tester.tap(find.text('click me'));
    expect(dismissed, 1);
  });

  testWidgets('action button fires its callback (NOT onDismiss synchronously)',
      (tester) async {
    var actionFired = 0;
    var dismissed = 0;
    await pump(
      tester,
      AlertEntry(
        type: AlertType.success,
        message: 'done',
        duration: Duration.zero,
        action: AppAlertAction(label: 'Show', onPressed: () => actionFired++),
      ),
      onDismiss: () => dismissed++,
    );
    await tester.tap(find.text('Show'));
    expect(actionFired, 1);
    expect(dismissed, 1);
  });

  testWidgets('hover (MouseRegion enter/exit) fires hover callbacks',
      (tester) async {
    var enter = 0;
    var exit = 0;
    await pump(
      tester,
      AlertEntry(
        type: AlertType.error,
        message: 'hover me',
        duration: const Duration(seconds: 6),
      ),
      onHoverEnter: () => enter++,
      onHoverExit: () => exit++,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(AlertPill)));
    await tester.pump();
    expect(enter, 1);

    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pump();
    expect(exit, 1);
  });
}
