import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_widget.dart';

void main() {
  group('TimelineWidget', () {
    testWidgets('should render timeline with duration', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimelineWidget(
              duration: const Duration(seconds: 10),
              position: const Duration(seconds: 5),
              onPositionChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.byType(TimelineWidget), findsOneWidget);
    });

    testWidgets('should call onPositionChanged when tapped', (tester) async {
      Duration? newPosition;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimelineWidget(
              duration: const Duration(seconds: 10),
              position: const Duration(seconds: 5),
              onPositionChanged: (pos) {
                newPosition = pos;
              },
            ),
          ),
        ),
      );

      // Tap at the center (should be around 5 seconds for 10 second duration)
      await tester.tapAt(tester.getCenter(find.byType(TimelineWidget)));
      await tester.pump();

      expect(newPosition, isNotNull);
      expect(newPosition!.inSeconds, greaterThan(0));
    });
  });
}
