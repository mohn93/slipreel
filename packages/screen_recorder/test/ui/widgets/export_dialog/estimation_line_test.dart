import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/export_estimator.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/estimation_line.dart';

void main() {
  Widget build({
    required double durationSec,
    required int bitrateKbps,
    ExportFormat format = ExportFormat.mp4,
    ExportEstimator estimator = const ExportEstimator(),
  }) {
    return MaterialApp(
      home: Scaffold(
        body: EstimationLine(
          durationSec: durationSec,
          bitrateKbps: bitrateKbps,
          format: format,
          estimator: estimator,
        ),
      ),
    );
  }

  testWidgets('renders formatted estimation line text', (tester) async {
    await tester.pumpWidget(
      build(durationSec: 10, bitrateKbps: 6000, format: ExportFormat.mp4),
    );
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('estimation_line_text')),
    );
    expect(text.data, contains('Estimation'));
    expect(text.data, contains('Export time'));
    expect(text.data, contains('Output size'));
  });

  testWidgets('uses ExportEstimator.formatLine output verbatim', (tester) async {
    const estimator = ExportEstimator(lastRealtimeMultiplier: 1.0);
    const durationSec = 5.0;
    const bitrateKbps = 6000;
    const format = ExportFormat.mp4;

    final expected = estimator.formatLine(
      durationSec: durationSec,
      bitrateKbps: bitrateKbps,
      format: format,
    );

    await tester.pumpWidget(
      build(
        durationSec: durationSec,
        bitrateKbps: bitrateKbps,
        format: format,
        estimator: estimator,
      ),
    );

    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('updates when inputs change', (tester) async {
    const estimatorA = ExportEstimator(lastRealtimeMultiplier: 1.0);
    const estimatorB = ExportEstimator(lastRealtimeMultiplier: 1.0);

    await tester.pumpWidget(
      build(
        durationSec: 5,
        bitrateKbps: 3000,
        format: ExportFormat.mp4,
        estimator: estimatorA,
      ),
    );
    final textA = tester.widget<Text>(
      find.byKey(const ValueKey('estimation_line_text')),
    ).data;

    await tester.pumpWidget(
      build(
        durationSec: 10,
        bitrateKbps: 6000,
        format: ExportFormat.mp4,
        estimator: estimatorB,
      ),
    );
    final textB = tester.widget<Text>(
      find.byKey(const ValueKey('estimation_line_text')),
    ).data;

    expect(textA, isNotNull);
    expect(textB, isNotNull);
    expect(textA, isNot(equals(textB)));
  });

  testWidgets('GIF format produces different output size than MP4',
      (tester) async {
    const estimator = ExportEstimator(lastRealtimeMultiplier: 1.0);
    const durationSec = 10.0;
    const bitrateKbps = 6000;

    await tester.pumpWidget(
      build(
        durationSec: durationSec,
        bitrateKbps: bitrateKbps,
        format: ExportFormat.mp4,
        estimator: estimator,
      ),
    );
    final mp4Text = tester.widget<Text>(
      find.byKey(const ValueKey('estimation_line_text')),
    ).data;

    await tester.pumpWidget(
      build(
        durationSec: durationSec,
        bitrateKbps: bitrateKbps,
        format: ExportFormat.gif,
        estimator: estimator,
      ),
    );
    final gifText = tester.widget<Text>(
      find.byKey(const ValueKey('estimation_line_text')),
    ).data;

    expect(mp4Text, isNot(equals(gifText)));
  });

  testWidgets('is right-aligned', (tester) async {
    await tester.pumpWidget(
      build(durationSec: 5, bitrateKbps: 6000),
    );
    final align = tester.widget<Align>(
      find.ancestor(
        of: find.byKey(const ValueKey('estimation_line_text')),
        matching: find.byType(Align),
      ).first,
    );
    expect(align.alignment, Alignment.centerRight);
  });
}
