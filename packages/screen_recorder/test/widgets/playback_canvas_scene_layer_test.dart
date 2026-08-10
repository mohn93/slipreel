import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';

void main() {
  testWidgets('cursor stays outside the scene-blur capture boundary', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    const cursorKey = ValueKey('cursor');
    const chromeKey = ValueKey('chrome');
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: buildInternalSceneBlurTree(
            boundaryKey: boundaryKey,
            body: const ColoredBox(color: Colors.black),
            blurOverlay: const SizedBox.expand(),
            sceneUnderlay: const SizedBox(key: chromeKey),
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
    expect(
      find.descendant(of: boundary, matching: find.byKey(chromeKey)),
      findsNothing,
    );
    expect(find.byKey(chromeKey), findsOneWidget);
  });

  testWidgets('blur filters the display outside the capture boundary', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 20,
            height: 10,
            child: buildInternalSceneBlurTree(
              boundaryKey: boundaryKey,
              stickyBackground: const ColoredBox(color: Colors.blue),
              body: const ColoredBox(color: Colors.red),
              blurOverlay: const Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: ColoredBox(color: Colors.green),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final boundary = find.byKey(boundaryKey);
    final filter = find.ancestor(
      of: boundary,
      matching: find.byType(ColorFiltered),
    );
    expect(filter, findsOneWidget);

    // Production captures synchronously from this boundary. The filter is an
    // ancestor, so the boundary image remains the full-opacity source scene.
    final renderBoundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = renderBoundary.toImageSync(pixelRatio: 1);
    expect(image.width, 20);
    expect(image.height, 10);
    image.dispose();
  });
}
