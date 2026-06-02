import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_overlay.dart';

Widget _harness(CutOverlay overlay) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 800, height: 60, child: overlay),
      ),
    );

void main() {
  group('CutOverlay', () {
    testWidgets('cursor x updates the cursorX notifier on hover', (tester) async {
      final cursorX = ValueNotifier<double?>(null);
      await tester.pumpWidget(_harness(CutOverlay(
        pixelsPerSecond: 50,
        totalEditedDuration: const Duration(seconds: 16),
        cursorX: cursorX,
        onCommitCut: (_) {},
        onExitMode: () {},
      )));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: const Offset(123, 30));
      await tester.pump();
      expect(cursorX.value, closeTo(123, 0.5));
    });

    testWidgets('tap calls onCommitCut with the edited-time at click x', (tester) async {
      Duration? committed;
      await tester.pumpWidget(_harness(CutOverlay(
        pixelsPerSecond: 50,
        totalEditedDuration: const Duration(seconds: 16),
        cursorX: ValueNotifier<double?>(null),
        onCommitCut: (d) => committed = d,
        onExitMode: () {},
      )));
      await tester.tapAt(const Offset(200, 30));
      expect(committed, const Duration(seconds: 4));
    });

    testWidgets('Esc fires onExitMode', (tester) async {
      var exited = false;
      await tester.pumpWidget(_harness(CutOverlay(
        pixelsPerSecond: 50,
        totalEditedDuration: const Duration(seconds: 16),
        cursorX: ValueNotifier<double?>(null),
        onCommitCut: (_) {},
        onExitMode: () => exited = true,
      )));
      final focusNode = tester.firstWidget<Focus>(find.byType(Focus)).focusNode!;
      focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(exited, true);
    });

    testWidgets('renders a dashed vertical indicator when cursor x is set', (tester) async {
      final cursorX = ValueNotifier<double?>(null);
      await tester.pumpWidget(_harness(CutOverlay(
        pixelsPerSecond: 50,
        totalEditedDuration: const Duration(seconds: 16),
        cursorX: cursorX,
        onCommitCut: (_) {},
        onExitMode: () {},
      )));
      cursorX.value = 200;
      await tester.pump();
      expect(find.byKey(const ValueKey('cut-overlay-dashed-indicator')), findsOneWidget);
    });
  });
}
