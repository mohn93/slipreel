import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('tooltip text appears after 500ms hover', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));

    // Before delay: no tooltip yet.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Cursor'), findsNothing);

    // After delay: tooltip visible.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsOneWidget);
  });

  testWidgets('tooltip overlay sits to the LEFT of the button',
      (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final buttonRect =
        tester.getRect(find.byType(SpringyIconButton));
    final tooltipRect = tester.getRect(find.text('Cursor'));
    expect(tooltipRect.right, lessThanOrEqualTo(buttonRect.left),
        reason: 'tooltip should be entirely left of the button');
  });

  testWidgets('hover-exit removes the tooltip', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsOneWidget);

    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsNothing);
  });
}
