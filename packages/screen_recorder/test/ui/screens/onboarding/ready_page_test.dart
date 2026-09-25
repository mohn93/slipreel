import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/onboarding/pages/ready_page.dart';

void main() {
  testWidgets('ready page describes the recording bar and opens it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var finished = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReadyPage(onFinish: () => finished = true)),
      ),
    );

    expect(find.text("You're ready to record"), findsOneWidget);
    expect(
      find.textContaining('choose Screen, Window, or Area'),
      findsOneWidget,
    );
    expect(find.text('Record my first video'), findsNothing);
    await tester.tap(find.text('Open recording bar'));
    expect(finished, isTrue);
    expect(tester.takeException(), isNull);
  });
}
