import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/desktop_dialog.dart';

void main() {
  Widget host() => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDesktopDialog<void>(
            context: context,
            builder: (_) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const DesktopDialogHeading(title: 'Dialog title'),
                  const SizedBox(height: 400),
                  TextButton(
                    onPressed: () {},
                    child: const Text('Last action'),
                  ),
                ],
              ),
            ),
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  );

  testWidgets('centers content and supports Escape and the close button', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final surface = find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first;
    expect(tester.getSize(surface).width, 520);
    expect(tester.getCenter(surface), const Offset(400, 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('keeps long content accessible in a small window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Last action'), 100);
    expect(find.text('Last action').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
