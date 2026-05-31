import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          // Constrain like the real inspector column so the picker
          // resolves a finite width.
          child: SizedBox(width: 300, child: child),
        ),
      ),
    ),
  );
}

void main() {
  const videoSize = Size(1920, 1080);

  testWidgets('renders with initial rect centered', (tester) async {
    final initial = Rect.fromCenter(
      center: const Offset(960, 540),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (_) {},
        onCommit: (_) {},
      ),
    );
    expect(find.byKey(const Key('zoom-placement-mini-frame')), findsOneWidget);
    expect(find.byKey(const Key('zoom-placement-inner-rect')), findsOneWidget);
  });

  testWidgets('drag to mini-frame center emits center in video coords',
      (tester) async {
    Rect? latestPreview;
    Rect? committed;
    final initial = Rect.fromCenter(
      center: const Offset(100, 100),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (r) => latestPreview = r,
        onCommit: (r) => committed = r,
      ),
    );

    final miniFrame =
        tester.getRect(find.byKey(const Key('zoom-placement-mini-frame')));
    final innerStart =
        tester.getCenter(find.byKey(const Key('zoom-placement-inner-rect')));
    final miniCenter = miniFrame.center;

    // Drag the inner rect by the delta from its current position to the
    // mini-frame center.
    await tester.timedDrag(
      find.byKey(const Key('zoom-placement-inner-rect')),
      miniCenter - innerStart,
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();

    expect(latestPreview, isNotNull);
    expect(committed, isNotNull);
    // Expect the inner rect to be centered in the video.
    expect(committed!.center.dx, closeTo(960, 1.0));
    expect(committed!.center.dy, closeTo(540, 1.0));
    // Size derived from videoSize / zoomLevel.
    expect(committed!.size.width, closeTo(960, 0.5));
    expect(committed!.size.height, closeTo(540, 0.5));
  });

  testWidgets('drag past top-left clamps to half-size center',
      (tester) async {
    Rect? committed;
    final initial = Rect.fromCenter(
      center: const Offset(960, 540),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (_) {},
        onCommit: (r) => committed = r,
      ),
    );

    final miniFrame =
        tester.getRect(find.byKey(const Key('zoom-placement-mini-frame')));
    final innerStart =
        tester.getCenter(find.byKey(const Key('zoom-placement-inner-rect')));
    // Aim well past the top-left corner of the mini-frame.
    final farTopLeft = miniFrame.topLeft - const Offset(200, 200);

    await tester.timedDrag(
      find.byKey(const Key('zoom-placement-inner-rect')),
      farTopLeft - innerStart,
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();

    expect(committed, isNotNull);
    // Clamped: rect's top-left at (0,0), so center is at half size.
    expect(committed!.center.dx, closeTo(480, 1.0));
    expect(committed!.center.dy, closeTo(270, 1.0));
  });

  testWidgets('emit cadence: many previews, exactly one commit',
      (tester) async {
    int previews = 0;
    int commits = 0;
    final initial = Rect.fromCenter(
      center: const Offset(960, 540),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (_) => previews++,
        onCommit: (_) => commits++,
      ),
    );

    final inner = find.byKey(const Key('zoom-placement-inner-rect'));
    final gesture = await tester.startGesture(tester.getCenter(inner));
    await gesture.moveBy(const Offset(5, 5));
    await tester.pump();
    await gesture.moveBy(const Offset(5, 5));
    await tester.pump();
    await gesture.moveBy(const Offset(5, 5));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(previews, greaterThanOrEqualTo(3));
    expect(commits, 1);
  });

  testWidgets('matches vertical (9:16) videoSize aspect', (tester) async {
    const verticalVideo = Size(1080, 1920);
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: verticalVideo,
        rect: Rect.fromCenter(
            center: const Offset(540, 960), width: 540, height: 960),
        zoomLevel: 2.0,
        onPreview: (_) {},
        onCommit: (_) {},
      ),
    );
    final miniFrame =
        tester.getRect(find.byKey(const Key('zoom-placement-mini-frame')));
    // Width 280 cap, so height = 280 * (1920/1080) ≈ 497.78.
    expect(miniFrame.width, closeTo(280, 0.5));
    expect(miniFrame.height / miniFrame.width,
        closeTo(verticalVideo.height / verticalVideo.width, 0.001));
  });
}
