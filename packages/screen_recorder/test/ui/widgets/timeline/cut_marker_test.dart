import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';

Widget _harness(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('CutMarker', () {
    testWidgets('compact state: no label when hiddenSeconds is zero',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(hiddenSeconds: Duration.zero, onTap: () {}),
      ));
      expect(find.byKey(const ValueKey('cut-marker-label')), findsNothing);
      expect(find.byKey(const ValueKey('cut-marker-scissors')), findsOneWidget);
    });

    testWidgets('labeled state: label shows X.Xs when hiddenSeconds > 0',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
            hiddenSeconds: const Duration(milliseconds: 1000),
            onTap: () {}),
      ));
      expect(find.text('1.0s'), findsOneWidget);
      expect(find.byKey(const ValueKey('cut-marker-scissors')), findsOneWidget);
    });

    testWidgets('label formats sub-second values with 1 decimal',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
            hiddenSeconds: const Duration(milliseconds: 250),
            onTap: () {}),
      ));
      expect(find.text('0.3s'), findsOneWidget);
    });

    testWidgets('label formats multi-second values with 1 decimal',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
            hiddenSeconds: const Duration(milliseconds: 12400),
            onTap: () {}),
      ));
      expect(find.text('12.4s'), findsOneWidget);
    });

    testWidgets('tap fires onTap callback', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_harness(
        CutMarker(hiddenSeconds: Duration.zero, onTap: () => tapped++),
      ));
      await tester.tap(find.byKey(const ValueKey('cut-marker-hit')));
      expect(tapped, 1);
    });

    testWidgets('dragFade collapses the marker opacity',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
          hiddenSeconds: Duration.zero,
          onTap: () {},
          dragFade: true,
        ),
      ));
      await tester.pumpAndSettle();
      final opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('cut-marker-fade')),
      );
      expect(opacity.opacity, lessThan(0.5));
    });
  });
}
