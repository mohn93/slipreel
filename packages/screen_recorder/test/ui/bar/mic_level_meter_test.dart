import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/mic_level_meter.dart';

void main() {
  Widget host(Stream<double> s) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 100, child: MicLevelMeter(levelStream: s)),
          ),
        ),
      );

  testWidgets('fill width tracks the level', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    await tester.pump();

    c.add(0.0);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 0.0);

    c.add(1.0);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 1.0);

    c.add(0.5);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 0.5);

    await c.close();
  });

  testWidgets('fill color shifts to amber then red near clip', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));

    Color fillColor() => (tester
            .widget<Container>(find.byKey(const Key('mic-meter-fill')))
            .decoration as BoxDecoration)
        .color!;

    c.add(0.5);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    final normal = fillColor();

    c.add(0.90);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    expect(fillColor(), isNot(normal)); // amber zone

    c.add(0.99);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    final red = fillColor();
    expect(red.red, greaterThan(red.green)); // reddish near clip

    await c.close();
  });

  testWidgets('clamps out-of-range levels', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(2.0);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 1.0);
    c.add(-1.0);
    await tester.pump(); // deliver the stream event → setState schedules a frame
    await tester.pump(); // build the scheduled frame
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 0.0);
    await c.close();
  });
}
