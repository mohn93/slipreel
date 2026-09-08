import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/compression_picker.dart';

void main() {
  Widget build({
    required CompressionTier value,
    required ValueChanged<CompressionTier> onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: CompressionPicker(value: value, onChanged: onChanged),
      ),
    );
  }

  testWidgets('renders all four tier labels', (tester) async {
    await tester.pumpWidget(
      build(value: CompressionTier.web, onChanged: (_) {}),
    );
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Social Media'), findsOneWidget);
    expect(find.text('Web'), findsOneWidget);
    expect(find.text('Web (Low)'), findsOneWidget);
  });

  testWidgets('shows Studio description for Studio tier', (tester) async {
    await tester.pumpWidget(
      build(value: CompressionTier.studio, onChanged: (_) {}),
    );
    final desc = tester.widget<Text>(
      find.byKey(const ValueKey('compression_description')),
    );
    expect(
      desc.data,
      'Highest quality, largest files.',
    );
  });

  testWidgets('shows Social Media description for socialMedia tier',
      (tester) async {
    await tester.pumpWidget(
      build(value: CompressionTier.socialMedia, onChanged: (_) {}),
    );
    final desc = tester.widget<Text>(
      find.byKey(const ValueKey('compression_description')),
    );
    expect(
      desc.data,
      'High quality for social uploads.',
    );
  });

  testWidgets('shows Web description for web tier', (tester) async {
    await tester.pumpWidget(
      build(value: CompressionTier.web, onChanged: (_) {}),
    );
    final desc = tester.widget<Text>(
      find.byKey(const ValueKey('compression_description')),
    );
    expect(
      desc.data,
      contains('Balanced quality and file size'),
    );
  });

  testWidgets('shows Web Low description for webLow tier', (tester) async {
    await tester.pumpWidget(
      build(value: CompressionTier.webLow, onChanged: (_) {}),
    );
    final desc = tester.widget<Text>(
      find.byKey(const ValueKey('compression_description')),
    );
    expect(desc.data, contains('Smallest files'));
  });

  testWidgets('tapping Social Media fires onChanged with socialMedia',
      (tester) async {
    CompressionTier? fired;
    await tester.pumpWidget(
      build(value: CompressionTier.web, onChanged: (v) => fired = v),
    );
    await tester.tap(
      find.byKey(const ValueKey('seg_btn_CompressionTier.socialMedia')),
    );
    await tester.pump();
    expect(fired, CompressionTier.socialMedia);
  });
}
