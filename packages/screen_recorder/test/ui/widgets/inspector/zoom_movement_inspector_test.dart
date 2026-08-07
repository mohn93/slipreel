import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

ZoomRegion _region({
  bool followCursor = false,
  FollowMode followMode = FollowMode.smart,
  ZoomMovement? movement,
}) =>
    ZoomRegion(
      rect: const Rect.fromLTWH(100, 100, 200, 200),
      startTime: Duration.zero,
      duration: const Duration(seconds: 3),
      zoomLevel: 2,
      followCursor: followCursor,
      followMode: followMode,
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
  testWidgets('follow styles expose only Smart and Centered', (tester) async {
    await _pump(tester, _region(followCursor: true), (_) {});
    await _scrollToText(tester, 'Follow style');

    expect(find.text('Smart'), findsOneWidget);
    expect(find.text('Centered'), findsOneWidget);
    expect(find.text('Bounded'), findsNothing);
    expect(find.text('Predictive'), findsNothing);
    expect(find.text('Lead time'), findsOneWidget);
  });

  testWidgets('legacy predictive projects display Smart as selected',
      (tester) async {
    await _pump(
      tester,
      _region(
        followCursor: true,
        followMode: FollowMode.predictive,
      ),
      (_) {},
    );
    await _scrollToText(tester, 'Follow style');

    final smart = tester.widget<InspectorChip>(
      find.widgetWithText(InspectorChip, 'Smart'),
    );
    expect(smart.selected, isTrue);
  });

  testWidgets('selecting Smart writes the explicit smart value',
      (tester) async {
    ZoomRegion? updated;
    await _pump(
      tester,
      _region(followCursor: true, followMode: FollowMode.centered),
      (z) => updated = z,
    );
    await _scrollToText(tester, 'Follow style');
    await tester.tap(find.text('Smart'));
    await tester.pumpAndSettle();

    expect(updated!.followMode, FollowMode.smart);
  });

  testWidgets('legacy bounded projects retain an explicit upgrade path',
      (tester) async {
    ZoomRegion? updated;
    await _pump(
      tester,
      _region(followCursor: true, followMode: FollowMode.bounded),
      (z) => updated = z,
    );
    await _scrollToText(tester, 'Follow style');

    final legacy = tester.widget<InspectorChip>(
      find.widgetWithText(InspectorChip, 'Bounded (Legacy)'),
    );
    expect(legacy.selected, isTrue);
    expect(find.text('Deadzone size'), findsOneWidget);
    expect(find.text('Lead time'), findsNothing);

    await tester.tap(find.text('Smart'));
    await tester.pumpAndSettle();
    expect(updated!.followMode, FollowMode.smart);
  });

  testWidgets('Centered hides Smart-only deadzone and anticipation controls',
      (tester) async {
    await _pump(
      tester,
      _region(followCursor: true, followMode: FollowMode.centered),
      (_) {},
    );
    await _scrollToText(tester, 'Follow style');

    expect(find.text('Deadzone size'), findsNothing);
    expect(find.text('Lead time'), findsNothing);
  });

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
