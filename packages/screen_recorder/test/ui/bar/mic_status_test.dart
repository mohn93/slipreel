import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/mic_level_meter.dart';
import 'package:screen_recorder/ui/bar/mic_status.dart';

void main() {
  Widget host(Stream<double> s) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 120, child: MicStatus(levelStream: s)),
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

  testWidgets('a quiet real mic (small non-zero floor) does NOT warn',
      (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    // A real mic in a silent room still has a noise floor above zero; it must
    // never trip the no-signal warning even held for a long time.
    c.add(0.02);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(warning, findsNothing);
    expect(find.byType(MicLevelMeter), findsOneWidget);
    await c.close();
  });

  testWidgets('literal-zero (no signal) warns after the timeout',
      (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    // Exactly 0.0 = a dead/virtual-silent input (e.g. VB-Cable with nothing
    // routed). Held past the no-signal window, it should warn.
    c.add(0.0);
    await tester.pump();
    expect(warning, findsNothing); // not immediately — only after the window
    await tester.pump(const Duration(seconds: 3));
    expect(warning, findsOneWidget);
    await c.close();
  });

  testWidgets('a brief zero followed by signal does NOT warn', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(0.0); // momentary startup silence
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    c.add(0.3); // audio starts before the no-signal window elapses
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(warning, findsNothing);
    expect(find.byType(MicLevelMeter), findsOneWidget);
    await c.close();
  });

  testWidgets('a returning signal clears the no-signal warning',
      (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(0.0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(warning, findsOneWidget);
    c.add(0.6); // signal returns
    await tester.pump();
    await tester.pump();
    expect(warning, findsNothing);
    expect(find.byType(MicLevelMeter), findsOneWidget);
    await c.close();
  });

  testWidgets('warns on a negative sentinel (device/engine error)',
      (tester) async {
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
}
