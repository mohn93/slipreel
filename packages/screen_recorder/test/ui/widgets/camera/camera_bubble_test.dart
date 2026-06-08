import 'package:flutter/material.dart';
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
}
