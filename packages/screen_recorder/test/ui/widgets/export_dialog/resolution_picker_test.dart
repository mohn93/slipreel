import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/resolution_picker.dart';

void main() {
  Widget build({
    required ExportResolution value,
    required Size sourceVideoSize,
    required ValueChanged<ExportResolution> onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ResolutionPicker(
          value: value,
          sourceVideoSize: sourceVideoSize,
          onChanged: onChanged,
        ),
      ),
    );
  }

  const hd1080Source = Size(1920, 1080);
  const uhd4kSource = Size(3840, 2160);

  testWidgets('renders 720p / 1080p / 4K options', (tester) async {
    await tester.pumpWidget(
      build(
        value: ExportResolution.r1080p,
        sourceVideoSize: hd1080Source,
        onChanged: (_) {},
      ),
    );
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('4K'), findsOneWidget);
  });

  testWidgets('4K button is disabled when source is 1080p', (tester) async {
    ExportResolution? fired;
    await tester.pumpWidget(
      build(
        value: ExportResolution.r1080p,
        sourceVideoSize: hd1080Source,
        onChanged: (v) => fired = v,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('seg_btn_ExportResolution.r4k')),
    );
    await tester.pump();
    expect(fired, isNull);
  });

  testWidgets('4K button is enabled when source is 4K', (tester) async {
    ExportResolution? fired;
    await tester.pumpWidget(
      build(
        value: ExportResolution.r1080p,
        sourceVideoSize: uhd4kSource,
        onChanged: (v) => fired = v,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('seg_btn_ExportResolution.r4k')),
    );
    await tester.pump();
    expect(fired, ExportResolution.r4k);
  });

  testWidgets('sub-label shows computed dimensions for 1080p', (tester) async {
    await tester.pumpWidget(
      build(
        value: ExportResolution.r1080p,
        sourceVideoSize: hd1080Source,
        onChanged: (_) {},
      ),
    );
    final label = tester.widget<Text>(
      find.byKey(const ValueKey('resolution_dim_label')),
    );
    expect(label.data, '1920px × 1080px');
  });

  testWidgets('sub-label updates when resolution changes to 720p',
      (tester) async {
    await tester.pumpWidget(
      build(
        value: ExportResolution.r720p,
        sourceVideoSize: hd1080Source,
        onChanged: (_) {},
      ),
    );
    final label = tester.widget<Text>(
      find.byKey(const ValueKey('resolution_dim_label')),
    );
    // 1920×1080 fitted to 720p height → 1280×720
    expect(label.data, '1280px × 720px');
  });

  testWidgets('tapping 720p fires onChanged with r720p', (tester) async {
    ExportResolution? fired;
    await tester.pumpWidget(
      build(
        value: ExportResolution.r1080p,
        sourceVideoSize: hd1080Source,
        onChanged: (v) => fired = v,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('seg_btn_ExportResolution.r720p')),
    );
    await tester.pump();
    expect(fired, ExportResolution.r720p);
  });
}
