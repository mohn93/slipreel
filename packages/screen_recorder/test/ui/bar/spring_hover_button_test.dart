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

    testWidgets('hover triggers a small inner shift; tilt vs translate not pinned',
        (tester) async {
      // Current feel: inner translate is paused and only 3D tilt drives the
      // child. Rotation around the child's centre still moves its top-left
      // by a few projected pixels. We assert "something moved within a sane
      // bound" rather than a specific direction so this test survives future
      // rebalancing between translate and tilt.
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final layoutTopLeft = _childTopLeft(tester);
      final buttonCentre = tester.getCenter(find.byType(SpringHoverButton));

      final topRight = Offset(buttonCentre.dx + 50, buttonCentre.dy - 16);

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: topRight);
      addTearDown(gesture.removePointer);

      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final shifted = _childTopLeft(tester);
      final delta = shifted - layoutTopLeft;

      // Some shift must happen — either translate or rotation-around-centre.
      expect(delta.distance, greaterThan(0.1),
          reason: 'hover should produce SOME visible inner movement');
      // Bounded — clamp + max tilt → ≤ ~6 px on either axis for this size.
      expect(delta.dx.abs(), lessThanOrEqualTo(6.0),
          reason: 'inner shift x should stay within sane bounds');
      expect(delta.dy.abs(), lessThanOrEqualTo(6.0),
          reason: 'inner shift y should stay within sane bounds');
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
