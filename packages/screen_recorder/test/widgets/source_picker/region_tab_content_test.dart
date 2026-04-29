import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/region_tab_content.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: child),
      );

  testWidgets('empty state shows Draw a region button', (tester) async {
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: null,
      displayName: null,
      onDraw: () {},
      isDrawing: false,
    )));
    expect(find.text('Draw a region'), findsOneWidget);
    expect(find.textContaining('Draw a region of your screen'), findsOneWidget);
  });

  testWidgets('selected state shows recap with size and display', (tester) async {
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 1280, heightPx: 720),
      displayName: 'Built-in Display',
      onDraw: () {},
      isDrawing: false,
    )));
    expect(find.textContaining('1280 × 720'), findsOneWidget);
    expect(find.textContaining('Built-in Display'), findsOneWidget);
    expect(find.text('Redraw'), findsOneWidget);
  });

  testWidgets('button tap calls onDraw', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: null,
      displayName: null,
      onDraw: () => taps++,
      isDrawing: false,
    )));
    await tester.tap(find.text('Draw a region'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('isDrawing disables button and shows spinner', (tester) async {
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: null,
      displayName: null,
      onDraw: () {},
      isDrawing: true,
    )));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
