import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

ZoomRegion _region({ZoomLook look = ZoomLook.classic}) => look.applyTo(
      ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 200),
        startTime: Duration.zero,
        duration: const Duration(seconds: 3),
        zoomLevel: 2,
        followCursor: false,
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  ZoomRegion zoom, {
  void Function(ZoomRegion)? onChanged,
  void Function(ZoomLook)? onApplyLookToAll,
  VoidCallback? onEffectChanged,
}) async {
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
              onChanged: onChanged ?? (_) {},
              onDelete: () {},
              onClose: () {},
              curveLibrary: FileCurveLibrary(),
              onCurveOverrideChanged: (_) {},
              videoSize: const Size(1920, 1080),
              onApplyLookToAll: onApplyLookToAll,
              onEffectChanged: onEffectChanged,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollToText(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

bool _chipSelected(WidgetTester tester, String label) =>
    tester.widget<InspectorChip>(find.widgetWithText(InspectorChip, label))
        .selected;

void main() {
  testWidgets('Look row lists the presets and highlights the current one',
      (tester) async {
    await _pump(tester, _region(look: ZoomLook.cinematic));
    await _scrollToText(tester, 'Look');

    for (final p in ZoomLook.presets) {
      expect(find.text(p.presetName!), findsOneWidget);
    }
    expect(_chipSelected(tester, 'Cinematic'), isTrue);
    expect(_chipSelected(tester, 'Classic'), isFalse);
    expect(_chipSelected(tester, 'Flat'), isFalse);
    expect(_chipSelected(tester, 'Showcase'), isFalse);
  });

  testWidgets('a custom tilt + movement mix highlights no preset',
      (tester) async {
    final custom = _region().copyWith(
      tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
      movement: const ZoomMovement(
        kind: ZoomMovementKind.pushIn,
        intensity: ZoomMovementIntensity.dramatic,
      ),
    );
    await _pump(tester, custom);
    await _scrollToText(tester, 'Look');

    for (final p in ZoomLook.presets) {
      expect(_chipSelected(tester, p.presetName!), isFalse);
    }
  });

  testWidgets('tapping a preset applies its tilt + movement and reveals',
      (tester) async {
    ZoomRegion? out;
    var reveals = 0;
    await _pump(
      tester,
      _region(),
      onChanged: (z) => out = z,
      onEffectChanged: () => reveals++,
    );
    await _scrollToText(tester, 'Look');
    await tester.tap(find.text('Showcase'));
    await tester.pumpAndSettle();

    expect(out, isNotNull);
    expect(ZoomLook.of(out!), ZoomLook.showcase);
    expect(out!.zoomLevel, 2);
    expect(reveals, 1);
  });

  testWidgets('tilt and movement chips also reveal the effect',
      (tester) async {
    var reveals = 0;
    await _pump(tester, _region(), onEffectChanged: () => reveals++);
    await _scrollToText(tester, '3D tilt');
    await tester.tap(find.text('Dramatic'));
    await tester.pumpAndSettle();
    expect(reveals, 1);

    await _scrollToText(tester, 'Movement');
    await tester.tap(find.text('Push-in'));
    await tester.pumpAndSettle();
    expect(reveals, 2);
  });

  testWidgets('Apply to all zooms hands the current look to the callback',
      (tester) async {
    ZoomLook? applied;
    await _pump(
      tester,
      _region(look: ZoomLook.showcase),
      onApplyLookToAll: (look) => applied = look,
    );
    await _scrollToText(tester, 'Apply to all zooms');
    await tester.tap(find.text('Apply to all zooms'));
    await tester.pumpAndSettle();

    expect(applied, ZoomLook.showcase);
  });

  testWidgets('Apply to all zooms is hidden without a handler',
      (tester) async {
    await _pump(tester, _region());
    await _scrollToText(tester, 'Look');
    expect(find.text('Apply to all zooms'), findsNothing);
  });

  testWidgets('tilt and movement intensity rows are labelled',
      (tester) async {
    await _pump(tester, _region(look: ZoomLook.cinematic));
    // The inspector body is a lazy ListView, so check each section while
    // it is scrolled into view rather than counting both labels at once.
    await _scrollToText(tester, '3D tilt');
    expect(
      find.text('Leans toward the side of the frame the zoom targets'),
      findsOneWidget,
    );
    expect(find.text('Intensity'), findsAtLeastNWidgets(1));

    await _scrollToText(tester, 'Push-in');
    expect(find.text('Intensity'), findsAtLeastNWidgets(1));
  });

  testWidgets('no movement intensity row when movement is off',
      (tester) async {
    await _pump(tester, _region(look: ZoomLook.flat));
    await _scrollToText(tester, 'Push-in');
    // Flat: tilt is off and movement is none, so neither row is labelled.
    expect(find.text('Intensity'), findsNothing);
  });
}
