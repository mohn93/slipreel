import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/mic_level_meter.dart';
import 'package:screen_recorder/ui/bar/mic_status.dart';

void main() {
  Widget host(Stream<double> s) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              child: MicStatus(
                levelStream: s,
                silenceTimeout: const Duration(milliseconds: 200),
              ),
            ),
          ),
        ),
      );

  final warning = find.byKey(const Key('mic-warning'));

  testWidgets('shows the meter (no warning) on normal levels', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(0.5);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(MicLevelMeter), findsOneWidget);
    expect(warning, findsNothing);
    await c.close();
  });

  testWidgets('warns after prolonged silence', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(0.0); // digital silence
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // past the timeout
    expect(warning, findsOneWidget);
    await c.close();
  });

  testWidgets('warns immediately on a negative sentinel', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(-1.0);
    await tester.pump();
    await tester.pump();
    expect(warning, findsOneWidget);
    await c.close();
  });

  testWidgets('clears the warning when a valid level returns', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(-1.0);
    await tester.pump();
    await tester.pump();
    expect(warning, findsOneWidget);
    c.add(0.6);
    await tester.pump();
    await tester.pump();
    expect(warning, findsNothing);
    expect(find.byType(MicLevelMeter), findsOneWidget);
    await c.close();
  });

  testWidgets('a quiet-but-nonzero floor does not warn', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(0.1); // ambient noise floor, above the silence epsilon
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(warning, findsNothing);
    await c.close();
  });
}
