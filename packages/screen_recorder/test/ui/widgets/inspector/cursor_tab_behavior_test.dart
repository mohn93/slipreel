import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/cursor_tab.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  Widget host(EditorProjectController controller) => ProviderScope(
    overrides: [
      editorProjectControllerProvider.overrideWith((ref) => controller),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: const Scaffold(body: CursorTab(canHideCursor: true)),
    ),
  );

  Finder switchFor(String label) {
    final row = find.ancestor(
      of: find.text(label),
      matching: find.byType(InspectorToggle),
    );
    return find.descendant(of: row, matching: find.byType(Switch));
  }

  testWidgets('behavior toggles write through to persistent project state', (
    tester,
  ) async {
    final controller = EditorProjectController();
    await tester.pumpWidget(host(controller));

    for (final label in ['Hide cursor if not moving', 'Loop cursor position']) {
      await tester.scrollUntilVisible(
        find.text(label),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(switchFor(label));
      await tester.pump();
    }

    expect(controller.current.cursorPostProcess.hideWhenIdle, isTrue);
    expect(controller.current.cursorPostProcess.loopPosition, isTrue);
    expect(
      tester.widget<Switch>(switchFor('Loop cursor position')).value,
      isTrue,
      reason: 'the switch must rebuild from project state, not local state',
    );
  });

  testWidgets('does not expose internal motion tuning controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(EditorProjectController()));

    expect(find.text('Debug'), findsNothing);
    expect(find.text('Experimental controls. Off by default.'), findsNothing);
    expect(find.text('Motion preset'), findsNothing);
    expect(find.text('Default'), findsNothing);
    expect(find.text('Snappy'), findsNothing);
    expect(find.text('Cinematic'), findsNothing);
    expect(find.text('Cursor delay'), findsNothing);
  });

  testWidgets('advanced cursor settings write through to persistent project state', (
    tester,
  ) async {
    final controller = EditorProjectController();
    await tester.pumpWidget(host(controller));

    // Remove cursor shakes toggle
    final shakeFinder = find.text('Remove cursor shakes');
    await tester.scrollUntilVisible(
      shakeFinder,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(switchFor('Remove cursor shakes'));
    await tester.pump();

    expect(controller.current.cursorPostProcess.removeShakes, isTrue);

    // Optimize cursor changes toggle
    final optimizeFinder = find.text('Optimize cursor changes');
    await tester.scrollUntilVisible(
      optimizeFinder,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(switchFor('Optimize cursor changes'));
    await tester.pump();

    expect(controller.current.cursorPostProcess.optimizeChanges, isTrue);

    // Remove cursor shakes threshold slider
    final thresholdSlider = find.byType(Slider).last;
    await tester.drag(thresholdSlider, const Offset(50, 0));
    await tester.pumpAndSettle();

    expect(controller.current.cursorPostProcess.shakeThresholdPx, isNot(20.0));

    // Reset button
    final resetButton = find.text('Reset').last;
    await tester.tap(resetButton);
    await tester.pumpAndSettle();

    expect(controller.current.cursorPostProcess.shakeThresholdPx, 20.0);
  });
}
