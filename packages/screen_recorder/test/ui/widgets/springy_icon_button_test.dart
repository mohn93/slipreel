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
  testWidgets('renders the supplied icon', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.mouse), findsOneWidget);
  });

  testWidgets('tap fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(SpringyIconButton));
    expect(taps, 1);
  });

  testWidgets('inactive icon color is textSecondary', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(Icons.mouse));
    expect(icon.color, AppPalette.midnight.textSecondary);
  });

  testWidgets('active icon color is accent', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: true,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(Icons.mouse));
    expect(icon.color, AppPalette.midnight.accent);
  });

  testWidgets('active background uses accentMuted (non-transparent)',
      (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: true,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    // Compare components separately to avoid legacy-int vs Color.from() inequality.
    // accentMuted = Color(0x2E7C6CFF): r=0x7C, g=0x6C, b=0xFF, alpha ~0.18 (46/255).
    final accentMuted = AppPalette.midnight.accentMuted;
    final found = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .any((c) {
      final d = c.decoration;
      if (d is! BoxDecoration || d.color == null) return false;
      final color = d.color!;
      return (color.r - accentMuted.r).abs() < 0.01 &&
          (color.g - accentMuted.g).abs() < 0.01 &&
          (color.b - accentMuted.b).abs() < 0.01 &&
          (color.a - accentMuted.a).abs() < 0.01;
    });
    expect(found, isTrue);
  });

  testWidgets('inactive background is transparent', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final found = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .any((c) {
      final d = c.decoration;
      return d is BoxDecoration && d.color == Colors.transparent;
    });
    expect(found, isTrue);
  });

  testWidgets('hover triggers a scale > 1.0', (tester) async {
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
    await tester.pumpAndSettle();

    // The spring overshoots ~10% above target; assert strictly > 1.0.
    final transform =
        tester.widget<Transform>(find.byType(Transform).first).transform;
    expect(transform.entry(0, 0), greaterThan(1.0));
  });

  testWidgets('disabled icon color is dimmer than enabled', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor — coming soon',
      isActive: false,
      isEnabled: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(Icons.mouse));
    final expectedAlpha = AppPalette.midnight.textSecondary.a * 0.35;
    expect(icon.color, isNotNull);
    expect(icon.color!.a, closeTo(expectedAlpha, 0.02));
  });

  testWidgets('disabled tap does NOT fire onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor — coming soon',
      isActive: false,
      isEnabled: false,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(SpringyIconButton));
    expect(taps, 0);
  });

  testWidgets('disabled hover background is dimmer than enabled hover',
      (tester) async {
    // Pump an enabled button first, capture its hover bg alpha.
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
    await tester.pumpAndSettle();

    double bgAlpha(WidgetTester t) {
      for (final c
          in t.widgetList<AnimatedContainer>(find.byType(AnimatedContainer))) {
        final d = c.decoration;
        if (d is BoxDecoration &&
            d.color != null &&
            d.color != Colors.transparent) {
          return d.color!.a;
        }
      }
      return 0.0;
    }

    final enabledHoverAlpha = bgAlpha(tester);
    expect(enabledHoverAlpha, greaterThan(0.0));

    // Now pump a disabled button and hover it.
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor — coming soon',
      isActive: false,
      isEnabled: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));
    await tester.pumpAndSettle();

    final disabledHoverAlpha = bgAlpha(tester);
    expect(disabledHoverAlpha, greaterThan(0.0));
    expect(disabledHoverAlpha, lessThan(enabledHoverAlpha));
  });

  testWidgets('hover exit returns scale to 1.0', (tester) async {
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
    await tester.pumpAndSettle();
    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pumpAndSettle();

    final transform =
        tester.widget<Transform>(find.byType(Transform).first).transform;
    expect(transform.entry(0, 0), closeTo(1.0, 0.01));
  });
}
