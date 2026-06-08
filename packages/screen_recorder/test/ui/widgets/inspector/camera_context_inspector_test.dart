import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/camera_context_inspector.dart';

void main() {
  CameraRegion region() => CameraRegion(
        startTime: const Duration(seconds: 1),
        duration: const Duration(seconds: 3),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.25,
      );

  Widget host({
    required CameraRegion region,
    required ValueChanged<CameraRegion> onChanged,
    VoidCallback? onDelete,
    VoidCallback? onClose,
  }) =>
      ProviderScope(
        overrides: [
          editorProjectControllerProvider
              .overrideWith((ref) => EditorProjectController()),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: const [AppPalette.midnight],
            useMaterial3: true,
          ),
          home: Scaffold(
            body: CameraContextInspector(
              region: region,
              regionNumber: 2,
              onChanged: onChanged,
              onDelete: onDelete ?? () {},
              onClose: onClose ?? () {},
            ),
          ),
        ),
      );

  testWidgets('size slider edits the region; delete + close fire',
      (tester) async {
    CameraRegion? changed;
    var deleted = false;
    var closed = false;
    await tester.pumpWidget(host(
      region: region(),
      onChanged: (r) => changed = r,
      onDelete: () => deleted = true,
      onClose: () => closed = true,
    ));

    expect(find.text('Camera 2'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(-200, 0));
    await tester.pump();
    expect(changed, isNotNull);

    await tester.tap(find.byKey(const Key('camera-region-delete')));
    expect(deleted, isTrue);

    await tester.tap(find.byKey(const Key('camera-region-close')));
    expect(closed, isTrue);
  });

  testWidgets(
      'position grid edits the SELECTED region (per-slice): tapping the '
      'top-left cell moves this region up-left, via onChanged', (tester) async {
    CameraRegion? changed;
    await tester.pumpWidget(host(
      region: region(), // starts bottom-right (0.8, 0.8)
      onChanged: (r) => changed = r,
    ));

    await tester.tap(find.byKey(const Key('camera-pos-0-0')));
    await tester.pump();

    expect(changed, isNotNull);
    expect(changed!.centerX, lessThan(0.5)); // moved left
    expect(changed!.centerY, lessThan(0.5)); // moved up
    expect(changed!.size, region().size); // size unchanged by a reposition
  });
}
