import 'dart:ui' show Rect;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';

ZoomRegion _region({bool followCursor = false, ZoomMovement? movement}) =>
    ZoomRegion(
      rect: const Rect.fromLTWH(100, 100, 200, 200),
      startTime: Duration.zero,
      duration: const Duration(seconds: 3),
      zoomLevel: 2,
      followCursor: followCursor,
      movement: movement ?? const ZoomMovement(),
    );

Future<void> _pump(WidgetTester tester, ZoomRegion zoom,
    void Function(ZoomRegion) onChanged) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SizedBox(
            height: 1000,
            child: ZoomContextInspector(
              zoom: zoom,
              zoomNumber: 1,
              onChanged: onChanged,
              onDelete: () {},
              onClose: () {},
              curveLibrary: FileCurveLibrary(),
              onCurveOverrideChanged: (_) {},
              videoSize: const Size(1920, 1080),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The Movement section sits below the fold inside the inspector's internal
/// [ListView], so scroll it into view before asserting on / tapping it.
Future<void> _scrollToText(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selecting Push-in sets the movement on the region',
      (tester) async {
    ZoomRegion? updated;
    await _pump(tester, _region(), (z) => updated = z);

    await _scrollToText(tester, 'Push-in');
    await tester.tap(find.text('Push-in'));
    await tester.pumpAndSettle();

    expect(updated, isNotNull);
    expect(updated!.movement.kind, ZoomMovementKind.pushIn);
  });

  testWidgets('Drift is hidden for follow-cursor zooms', (tester) async {
    await _pump(tester, _region(followCursor: true), (_) {});
    await _scrollToText(tester, 'Sweep');
    expect(find.text('Drift'), findsNothing);
  });

  testWidgets('Drift is offered for manual (in-place) zooms', (tester) async {
    await _pump(tester, _region(followCursor: false), (_) {});
    await _scrollToText(tester, 'Drift');
    expect(find.text('Drift'), findsOneWidget);
  });

  testWidgets('intensity control appears once a movement is chosen',
      (tester) async {
    await _pump(
        tester,
        _region(movement: const ZoomMovement(kind: ZoomMovementKind.sweep)),
        (_) {});
    await _scrollToText(tester, 'Subtle');
    expect(find.text('Subtle'), findsWidgets);
    expect(find.text('Dramatic'), findsWidgets);
  });
}
