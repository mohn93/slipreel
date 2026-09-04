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

  testWidgets('literal zero stays healthy because silence is valid audio',
      (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(0.0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
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
