import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/camera_tab.dart';

void main() {
  Widget host(EditorProjectController controller, {bool hasCamera = true}) =>
      ProviderScope(
        overrides: [
          editorProjectControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: const [AppPalette.midnight],
            useMaterial3: true,
          ),
          home: Scaffold(body: CameraTab(hasCamera: hasCamera)),
        ),
      );

  testWidgets('no sidecar => shows the disabled placeholder', (tester) async {
    await tester.pumpWidget(host(EditorProjectController(), hasCamera: false));
    expect(find.textContaining('No camera'), findsOneWidget);
  });

  testWidgets('toggling Mirror writes through to cameraSettings',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(host(c));
    expect(c.current.cameraSettings.mirror, isTrue);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('camera-mirror-toggle')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pump();
    expect(c.current.cameraSettings.mirror, isFalse);
  });

  testWidgets('selecting a shape chip updates the shape', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(host(c));
    await tester.tap(find.text('Horizontal'));
    await tester.pump();
    expect(c.current.cameraSettings.shape, CameraShape.horizontal);
  });
}
