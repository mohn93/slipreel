import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_pill.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('shows the elapsed time as m:ss', (tester) async {
    await tester.pumpWidget(wrap(
      const RecordingPill(elapsed: Duration(seconds: 65), onStop: _noop),
    ));
    expect(find.text('1:05'), findsOneWidget);
  });

  testWidgets('tapping stop fires onStop', (tester) async {
    var stopped = false;
    await tester.pumpWidget(wrap(
      RecordingPill(elapsed: Duration.zero, onStop: () => stopped = true),
    ));
    await tester.tap(find.byKey(const Key('pill-stop')));
    expect(stopped, isTrue);
  });
}

void _noop() {}
