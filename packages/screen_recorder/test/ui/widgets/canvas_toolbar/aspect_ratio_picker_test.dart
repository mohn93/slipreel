import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart';
import 'package:slipreel_engine/models/output_aspect.dart';

void main() {
  Future<void> pump(WidgetTester tester, {
    required OutputAspect current,
    required void Function(OutputAspect) onChanged,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AspectRatioPicker(current: current, onChanged: onChanged),
        ),
      ),
    ));
  }

  testWidgets('renders the current label', (tester) async {
    await pump(tester, current: OutputAspect.vertical9x16, onChanged: (_) {});
    expect(find.text('Vertical 9:16'), findsOneWidget);
  });

  testWidgets('opens a menu with all 7 entries on tap', (tester) async {
    await pump(tester, current: OutputAspect.auto, onChanged: (_) {});
    await tester.tap(find.byType(AspectRatioPicker));
    await tester.pumpAndSettle();
    for (final v in OutputAspect.values) {
      expect(find.text(v.label), findsWidgets,
          reason: 'expected entry for ${v.label}');
    }
  });

  testWidgets('fires onChanged with the chosen variant', (tester) async {
    OutputAspect? chosen;
    await pump(
      tester,
      current: OutputAspect.auto,
      onChanged: (v) => chosen = v,
    );
    await tester.tap(find.byType(AspectRatioPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wide 16:9').last);
    await tester.pumpAndSettle();
    expect(chosen, OutputAspect.wide16x9);
  });

  testWidgets('shows a checkmark next to the current entry', (tester) async {
    await pump(
      tester,
      current: OutputAspect.square1x1,
      onChanged: (_) {},
    );
    await tester.tap(find.byType(AspectRatioPicker));
    await tester.pumpAndSettle();
    final activeRow = find.ancestor(
      of: find.text('Square 1:1'),
      matching: find.byType(MenuItemButton),
    );
    expect(activeRow, findsOneWidget);
    expect(
      find.descendant(of: activeRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });
}
