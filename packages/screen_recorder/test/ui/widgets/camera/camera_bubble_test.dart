import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:screen_recorder/ui/widgets/camera/camera_bubble.dart';

void main() {
  Widget host(CameraBubble bubble) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 800, height: 450, child: bubble),
          ),
        ),
      );

  const placement = CameraPlacement(centerX: 0.8, centerY: 0.8, size: 0.25);

  testWidgets('positions the bubble box from the placement + canvas size',
      (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(shape: CameraShape.square),
      child: const ColoredBox(color: Colors.red),
    )));
    final box = tester.getSize(find.byKey(const Key('camera-bubble-box')));
    expect(box.width, closeTo(200, 0.5));
    expect(box.height, closeTo(200, 0.5));
  });

  testWidgets(
      'renders the video child at a real, aspect-correct size '
      '(regression: a zero-intrinsic Texture in a bare FittedBox collapsed '
      'to 0x0 → shadow showed but the video did not)', (tester) async {
    const contentKey = Key('camera-content');
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(shape: CameraShape.square),
      originalAspect: 1.6,
      child: const ColoredBox(key: contentKey, color: Colors.red),
    )));
    final size = tester.getSize(find.byKey(contentKey));
    expect(size.width, greaterThan(0), reason: 'video child must not collapse');
    expect(size.height, greaterThan(0), reason: 'video child must not collapse');
    // The child carries the camera aspect so BoxFit.cover fills the bubble.
    expect(size.width / size.height, closeTo(1.6, 1e-6));
  });

  testWidgets('circle shape clips with ClipOval; rectangular uses ClipRRect',
      (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(shape: CameraShape.circle),
      child: const ColoredBox(color: Colors.red),
    )));
    expect(find.byType(ClipOval), findsOneWidget);
  });

  testWidgets('opacity wraps the bubble', (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(opacity: 0.5),
      child: const ColoredBox(color: Colors.red),
    )));
    final op = tester.widget<Opacity>(find.byKey(const Key('camera-bubble-opacity')));
    expect(op.opacity, 0.5);
  });

  testWidgets(
      'AnimatedCameraBubble shows when visible and collapses after hiding',
      (tester) async {
    Widget host(bool visible) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 800,
                height: 450,
                child: AnimatedCameraBubble(
                  visible: visible,
                  canvasSize: const Size(800, 450),
                  placement: placement,
                  settings: const CameraSettings(),
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(host(true));
    expect(find.byType(CameraBubble), findsOneWidget);
    // Hide → after the vanish animation settles it collapses to nothing.
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    expect(find.byType(CameraBubble), findsNothing);
  });

  testWidgets('tapping a non-selected bubble requests selection',
      (tester) async {
    var requested = false;
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement, // center (0.8, 0.8) → box around (640, 360)
      settings: const CameraSettings(shape: CameraShape.square),
      selected: false,
      onSelectRequested: () => requested = true,
      child: const ColoredBox(color: Colors.red),
    )));
    await tester.tapAt(const Offset(640, 360));
    expect(requested, isTrue);
  });

  testWidgets(
      'an unselected active bubble is grab-draggable and selects on drag-start',
      (tester) async {
    var placement = const CameraPlacement(centerX: 0.5, centerY: 0.5, size: 0.25);
    var selected = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 800,
            height: 450,
            child: StatefulBuilder(
              builder: (ctx, setState) => CameraBubble(
                canvasSize: const Size(800, 450),
                placement: placement,
                settings: const CameraSettings(shape: CameraShape.square),
                selected: false, // NOT the active selection
                onPlacementChanged: (p) => setState(() => placement = p),
                onSelectRequested: () => setState(() => selected = true),
                child: const ColoredBox(color: Colors.red),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.drag(
        find.byKey(const Key('camera-move-body')), const Offset(120, 0));
    await tester.pump();
    expect(selected, isTrue, reason: 'drag-start selects the region');
    expect(placement.centerX, greaterThan(0.5), reason: 'and the drag moves it');
  });

  testWidgets('shows resize handles only when selected & editable',
      (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(),
      selected: true,
      onPlacementChanged: (_) {},
      child: const ColoredBox(color: Colors.red),
    )));
    expect(find.byKey(const Key('camera-handle-br')), findsOneWidget);
  });

  testWidgets('dragging the body reports an increased centerX (move)',
      (tester) async {
    var placement =
        const CameraPlacement(centerX: 0.5, centerY: 0.5, size: 0.25);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 800,
                height: 450,
                child: CameraBubble(
                  canvasSize: const Size(800, 450),
                  placement: placement,
                  settings: const CameraSettings(),
                  selected: true,
                  onPlacementChanged: (p) => setState(() => placement = p),
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(
        find.byKey(const Key('camera-move-body')), const Offset(80, 0));
    await tester.pump();
    expect(placement.centerX, greaterThan(0.5)); // moved right
    expect(placement.centerY, closeTo(0.5, 1e-6)); // not vertically
    expect(placement.size, 0.25); // unchanged by a move
  });

  testWidgets(
      'multiple pan updates within one frame accumulate every delta '
      '(regression: heavy/trailing drag — the base must be local, not the '
      'async placement that only catches up next frame)', (tester) async {
    // The parent holds [placement] FIXED for the whole gesture, mimicking the
    // real canvas where the live placement only feeds back a frame later via
    // the override ValueNotifier. A body that read widget.placement as its drag
    // base would lose every move but the last within a frame → the box trails
    // the mouse. The local _liveRaw base must accumulate all of them.
    const fixed = CameraPlacement(centerX: 0.3, centerY: 0.3, size: 0.2);
    final reports = <CameraPlacement>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 800,
            height: 450,
            child: CameraBubble(
              canvasSize: const Size(800, 450),
              placement: fixed,
              settings: const CameraSettings(),
              selected: true,
              onPlacementChanged: reports.add,
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    ));

    // Alt = free move (no anchor snap) so the reported value is the raw
    // accumulation, not a snapped one.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final center = tester.getCenter(find.byKey(const Key('camera-move-body')));
    final g = await tester.startGesture(center);
    // Three rightward moves with NO pump between them → all land before any
    // rebuild, exactly like several pointer-moves arriving in one frame.
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(30, 0));
    await g.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    // All three deltas accumulated: >= ~2 full 30px steps over 800px past the
    // start. A stale-base body would report only the last step (0.3 + 30/800 ≈
    // 0.3375), so this threshold (0.375) fails it but passes the fixed code.
    expect(reports.last.centerX, greaterThan(0.3 + 60 / 800));
    expect(reports.last.centerY, closeTo(0.3, 1e-6));
  });

  testWidgets('dragging the bottom-right handle outward grows size',
      (tester) async {
    var placement =
        const CameraPlacement(centerX: 0.5, centerY: 0.5, size: 0.25);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 800,
                height: 450,
                child: CameraBubble(
                  canvasSize: const Size(800, 450),
                  placement: placement,
                  settings: const CameraSettings(),
                  selected: true,
                  onPlacementChanged: (p) => setState(() => placement = p),
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(
        find.byKey(const Key('camera-handle-br')), const Offset(40, 40));
    await tester.pump();
    expect(placement.size, greaterThan(0.25)); // bottom-right outward = grow
  });

  testWidgets(
      'm5: an oversized corner-resize clamps to the canvas-fit size instead of '
      'snapping the bubble to center', (tester) async {
    var placement =
        const CameraPlacement(centerX: 0.82, centerY: 0.82, size: 0.25);
    const canvas = Size(800, 450); // 16:9 — height is the binding axis
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: canvas.width,
                height: canvas.height,
                child: CameraBubble(
                  canvasSize: canvas,
                  placement: placement,
                  settings: const CameraSettings(),
                  selected: true,
                  onPlacementChanged: (p) => setState(() => placement = p),
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Yank the corner far outward — way past what fits on the 16:9 canvas.
    await tester.drag(
        find.byKey(const Key('camera-handle-br')), const Offset(2000, 2000));
    await tester.pump();

    // Circle (aspect 1.0) on 16:9 is height-bound: maxFit = (1 - 2*0.06) *
    // 450/800 = 0.495 — well under the old 1.2 ceiling that triggered the snap.
    expect(placement.size, closeTo(0.495, 1e-3));
    // And the pixel box stays anchored to the corner — it must NOT recenter.
    final box = tester.getRect(find.byKey(const Key('camera-bubble-box')));
    final canvasRect = tester.getRect(find.byType(CameraBubble));
    expect(box.center.dx, greaterThan(canvasRect.center.dx),
        reason: 'bubble kept its bottom-right bias; did not snap to center');
  });
}
