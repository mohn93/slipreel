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

  double fillFactor(WidgetTester t) => t
      .widget<FractionallySizedBox>(find.ancestor(
          of: find.byKey(const Key('mic-meter-fill')),
          matching: find.byType(FractionallySizedBox)))
      .widthFactor!;
  double peakFactor(WidgetTester t) => t
      .widget<FractionallySizedBox>(find.ancestor(
          of: find.byKey(const Key('mic-meter-peak')),
          matching: find.byType(FractionallySizedBox)))
      .widthFactor!;

  /// Pumps [n] frames at [frameMs] milliseconds each to drive the ticker.
  Future<void> _pumpFrames(WidgetTester tester, int n,
      {int frameMs = 16}) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(Duration(milliseconds: frameMs));
    }
  }

  testWidgets('fill springs up toward the level', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(1.0);
    await tester.pump(); // deliver stream event
    // ~500 ms at 16 ms/frame ≈ 31 frames — enough for the spring to reach >0.6
    await _pumpFrames(tester, 31);
    expect(fillFactor(tester), greaterThan(0.6));
    await c.close();
  });

  testWidgets('peak holds above the fill, then decays', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(1.0);
    await tester.pump();
    await _pumpFrames(tester, 25); // ~400 ms — fill + peak near 1
    c.add(0.0);
    await tester.pump();
    await _pumpFrames(tester, 8); // ~120 ms — fill springs down, peak holds
    expect(peakFactor(tester), greaterThan(fillFactor(tester)));
    // ~2.4 s — short hold (0.3 s) then faster decay (0.6/s) brings peak well down.
    await _pumpFrames(tester, 150);
    expect(peakFactor(tester), lessThan(0.5));
    await c.close();
  });

  testWidgets('peak band renders with non-zero size', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(1.0);
    await tester.pump();
    await _pumpFrames(tester, 20); // peak rises off zero
    // The band must have real width (∝ peak) and fill the meter height — a
    // zero-size box would paint nothing.
    final size = tester.getSize(find.byKey(const Key('mic-meter-peak')));
    expect(size.width, greaterThan(0));
    expect(size.height, greaterThan(0));
    await c.close();
  });

  testWidgets('clamps out-of-range levels', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(5.0);
    await tester.pump();
    await _pumpFrames(tester, 31); // ~500 ms of spring animation
    expect(fillFactor(tester), lessThanOrEqualTo(1.0));
    await c.close();
  });
}
