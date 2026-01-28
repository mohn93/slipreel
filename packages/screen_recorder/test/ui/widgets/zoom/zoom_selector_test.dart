import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_selector.dart';

void main() {
  group('ZoomSelector', () {
    testWidgets('should render overlay when enabled', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomSelector(
              enabled: true,
              videoSize: const Size(800, 600),
              onRegionSelected: (rect) {},
              child: Container(
                width: 800,
                height: 600,
                color: Colors.black,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(ZoomSelector), findsOneWidget);
    });

    testWidgets('should detect tap and create region', (tester) async {
      Rect? selectedRect;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomSelector(
              enabled: true,
              videoSize: const Size(800, 600),
              onRegionSelected: (rect) {
                selectedRect = rect;
              },
              child: Container(
                width: 800,
                height: 600,
                color: Colors.black,
              ),
            ),
          ),
        ),
      );

      // Tap to create zoom region
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      expect(selectedRect, isNotNull);
      expect(selectedRect!.center, const Offset(400, 300));
    });

    testWidgets('should allow dragging to resize region', (tester) async {
      Rect? selectedRect;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomSelector(
              enabled: true,
              videoSize: const Size(800, 600),
              onRegionSelected: (rect) {
                selectedRect = rect;
              },
              child: Container(
                width: 800,
                height: 600,
                color: Colors.black,
              ),
            ),
          ),
        ),
      );

      // Drag to create region
      await tester.dragFrom(
        const Offset(300, 250),
        const Offset(200, 150),
      );
      await tester.pump();

      expect(selectedRect, isNotNull);
      expect(selectedRect!.width, greaterThan(0));
      expect(selectedRect!.height, greaterThan(0));
    });
  });
}
