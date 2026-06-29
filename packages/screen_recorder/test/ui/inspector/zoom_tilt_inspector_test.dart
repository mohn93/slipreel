// packages/screen_recorder/test/ui/inspector/zoom_tilt_inspector_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

ZoomRegion _zoom({Tilt3D tilt = const Tilt3D()}) => ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2,
      videoBounds: const Size(100, 100),
      tilt: tilt,
    );

Future<void> _pump(WidgetTester tester, ZoomRegion zoom,
    ValueChanged<ZoomRegion> onChanged) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            height: 800,
            child: ZoomContextInspector(
              zoom: zoom,
              zoomNumber: 1,
              onChanged: onChanged,
              onDelete: () {},
              onClose: () {},
              curveLibrary: FileCurveLibrary(),
              onCurveOverrideChanged: (_) {},
              videoSize: const Size(100, 100),
            ),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('toggling 3D on sets subtle; off sets flat', (tester) async {
    ZoomRegion? out;
    await _pump(tester, _zoom(), (z) => out = z);
    // Find the Switch belonging to the '3D tilt' InspectorToggle row.
    expect(find.text('3D tilt'), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.widgetWithText(InspectorToggle, '3D tilt'),
      matching: find.byType(Switch),
    ));
    await tester.pump();
    expect(out!.tilt, const Tilt3D(style: ZoomTiltStyle.subtle));

    await _pump(tester, _zoom(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
        (z) => out = z);
    expect(find.text('3D tilt'), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.widgetWithText(InspectorToggle, '3D tilt'),
      matching: find.byType(Switch),
    ));
    await tester.pump();
    expect(out!.tilt, const Tilt3D());
  });

  testWidgets('Dramatic chip sets dramatic style', (tester) async {
    ZoomRegion? out;
    await _pump(tester, _zoom(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
        (z) => out = z);
    await tester.tap(find.text('Dramatic'));
    await tester.pump();
    expect(out!.tilt.style, ZoomTiltStyle.dramatic);
  });
}
