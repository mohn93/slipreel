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
  });
}
