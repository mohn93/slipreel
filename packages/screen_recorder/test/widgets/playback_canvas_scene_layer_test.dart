import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';

void main() {
  testWidgets('cursor stays outside the scene-blur capture boundary', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    const cursorKey = ValueKey('cursor');
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: buildInternalSceneBlurTree(
            boundaryKey: boundaryKey,
            body: const ColoredBox(color: Colors.black),
            blurOverlay: const SizedBox.expand(),
            cursorOverlay: const SizedBox(key: cursorKey),
          ),
        ),
      ),
    );

    final boundary = find.byKey(boundaryKey);
    expect(boundary, findsOneWidget);
    expect(
      find.descendant(of: boundary, matching: find.byKey(cursorKey)),
      findsNothing,
    );
    expect(find.byKey(cursorKey), findsOneWidget);
  });
}
