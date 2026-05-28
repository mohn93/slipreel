import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';

const Key kChildKey = Key('inner-child');

Widget _harness({VoidCallback? onTap}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 120,
          height: 40,
          child: SpringHoverButton(
            onTap: onTap,
            child: const Center(
              child: Text('Hello', key: kChildKey),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Returns the global (screen-space) top-left of the inner child as
/// rendered. Useful for asserting how far the child has shifted from its
/// layout position.
Offset _childTopLeft(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(find.byKey(kChildKey));
  return box.localToGlobal(Offset.zero);
}

void main() {
  group('SpringHoverButton', () {
    testWidgets('child sits at its layout position when not hovered',
        (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // Without hover, the child should be at its layout position. We
      // capture its position twice across a few ticker frames and assert
      // it doesn't drift (no idle motion).
      final p0 = _childTopLeft(tester);
      await tester.pump(const Duration(milliseconds: 200));
      final p1 = _childTopLeft(tester);

      expect((p1 - p0).distance, lessThan(0.5),
          reason: 'child must be stationary when not hovered');
    });

    testWidgets(
        'hovering up-and-right shifts the child up-and-right within clamp',
        (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final layoutTopLeft = _childTopLeft(tester);
      final buttonCentre = tester.getCenter(find.byType(SpringHoverButton));

      // Hover at the button's top-right corner. In centre-relative coords
      // that's (+w/2, -h/2) → positive dx, negative dy → child should shift
      // toward upper-right (positive dx, negative dy from its layout pos).
      final topRight = Offset(buttonCentre.dx + 50, buttonCentre.dy - 16);

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: topRight);
      addTearDown(gesture.removePointer);

      // Let the inner spring approach its target. zeta 0.9 settles quickly;
      // 25 × 16ms frames (~400ms) is plenty past the critical-damping
      // window for a small step.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final shifted = _childTopLeft(tester);
      final delta = shifted - layoutTopLeft;

      // Direction: hovering upper-right → child shifts upper-right.
      expect(delta.dx, greaterThan(0.0),
          reason: 'child should shift right when cursor is to the right');
      expect(delta.dy, lessThan(0.0),
          reason: 'child should shift up when cursor is above centre');

      // Magnitude: clamp ±4 × ±3 px. Allow a small slack for spring
      // not-fully-settled.
      expect(delta.dx.abs(), lessThanOrEqualTo(4.5),
          reason: 'inner dx clamp is ±4');
      expect(delta.dy.abs(), lessThanOrEqualTo(3.5),
          reason: 'inner dy clamp is ±3');
    });

    testWidgets('child glides back home after hover exit', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final layoutTopLeft = _childTopLeft(tester);
      final buttonCentre = tester.getCenter(find.byType(SpringHoverButton));

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(
          location: Offset(buttonCentre.dx + 50, buttonCentre.dy - 16));
      addTearDown(gesture.removePointer);

      // Settle into hover.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final hovered = _childTopLeft(tester);
      final hoveredMag = (hovered - layoutTopLeft).distance;

      // Move pointer well off the widget to trigger exit.
      await gesture.moveTo(Offset(buttonCentre.dx + 500, buttonCentre.dy));

      // Pump a fair bit so the inner springs (and the pill) wind down.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final after = _childTopLeft(tester);
      final afterMag = (after - layoutTopLeft).distance;

      expect(afterMag, lessThan(hoveredMag * 0.4),
          reason: 'child should trend back toward its layout position on exit');
    });
  });
}
