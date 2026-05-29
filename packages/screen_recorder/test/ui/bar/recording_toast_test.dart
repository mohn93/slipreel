import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_toast.dart';

void main() {
  testWidgets('renders the message and auto-dismisses', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Builder(builder: (ctx) {
        return Scaffold(body: ElevatedButton(
          onPressed: () => RecordingToast.show(ctx, 'Hello toast'),
          child: const Text('go'),
        ));
      }),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('Hello toast'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Hello toast'), findsNothing);
  });
}
