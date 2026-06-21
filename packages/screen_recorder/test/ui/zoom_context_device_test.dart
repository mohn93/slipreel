import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';

/// For an iPhone/iPad recording there is no cursor, so the zoom inspector's
/// cursor-follow controls are meaningless. The inspector hides them, always
/// offers manual placement, and explains why.
Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SizedBox(width: 380, height: 700, child: child),
      ),
    );

ZoomContextInspector _inspector({required bool isDevice}) =>
    ZoomContextInspector(
      zoom: ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 400, 300),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      ),
      zoomNumber: 1,
      onChanged: (_) {},
      onDelete: () {},
      onClose: () {},
      curveLibrary: FileCurveLibrary(),
      onCurveOverrideChanged: (_) {},
      videoSize: const Size(400, 300),
      isDevice: isDevice,
    );

void main() {
  testWidgets(
      'device zoom inspector hides cursor-follow toggle and shows the note',
      (tester) async {
    await tester.pumpWidget(_host(_inspector(isDevice: true)));

    expect(find.text('Auto-zoom on cursor'), findsNothing);
    expect(find.textContaining('position the zoom manually'), findsOneWidget);
  });

  testWidgets('normal zoom inspector keeps the cursor-follow toggle',
      (tester) async {
    await tester.pumpWidget(_host(_inspector(isDevice: false)));

    expect(find.text('Auto-zoom on cursor'), findsOneWidget);
    expect(find.textContaining('position the zoom manually'), findsNothing);
  });
}
