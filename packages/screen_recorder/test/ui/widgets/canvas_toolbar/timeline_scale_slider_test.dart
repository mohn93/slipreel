import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/timeline_scale_slider.dart';

Widget _host({
  required EditorProjectController controller,
  Duration playhead = Duration.zero,
  double previewPlaybackSpeed = 1.0,
  ValueChanged<double>? onPreviewSpeedChanged,
}) =>
    ProviderScope(
      overrides: [
        editorProjectControllerProvider
            .overrideWith((ref) => controller),
      ],
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: Center(
            child: TimelineScaleSlider(
              playheadPosition: playhead,
              previewPlaybackSpeed: previewPlaybackSpeed,
              onPreviewSpeedChanged: onPreviewSpeedChanged ?? (_) {},
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('thumb sits at left edge at scale=1.0', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 0.0);
  });

  testWidgets('thumb sits at right edge at scale=8.0', (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(8.0);
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 1.0);
  });

  testWidgets('thumb sits near 0.5 at scale=sqrt(8) ≈ 2.83',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(math.sqrt(8.0));
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, closeTo(0.5, 0.01));
  });

  testWidgets('onChanged invokes controller with log-mapped value and anchor',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(
      controller: c,
      playhead: const Duration(seconds: 4),
    ));
    await tester.pumpAndSettle();

    final sliderFinder = find.byType(Slider);
    // Drag the thumb to about the middle.
    final center = tester.getCenter(sliderFinder);
    await tester.dragFrom(center, Offset.zero);  // no-op start
    final slider = tester.widget<Slider>(sliderFinder);
    slider.onChanged?.call(0.5);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(math.sqrt(8.0), 0.01));
    expect(c.current.pendingScaleAnchor, const Duration(seconds: 4));
  });

  testWidgets('tooltip waitDuration is 400ms', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.waitDuration, const Duration(milliseconds: 400));
  });

  testWidgets('preview speed badge shows the current speed', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(
      controller: c,
      previewPlaybackSpeed: 4.0,
    ));
    await tester.pumpAndSettle();
    // The badge renders "4×" (no decimals for integer-valued speeds).
    expect(find.text('4×'), findsOneWidget);
  });

  testWidgets('tapping the preview speed badge opens a menu with 1×/2×/4×/8×',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(
      controller: c,
      previewPlaybackSpeed: 1.0,
    ));
    await tester.pumpAndSettle();

    // The closed badge shows "1×". Tap it to open the menu.
    await tester.tap(find.text('1×'));
    await tester.pumpAndSettle();

    // The menu now has menu items for all four options. The closed
    // badge's "1×" is still on-screen, so we expect at least two "1×"
    // matches (badge + menu item).
    expect(find.text('1×'), findsWidgets);
    expect(find.text('2×'), findsOneWidget);
    expect(find.text('4×'), findsOneWidget);
    expect(find.text('8×'), findsOneWidget);
  });

  testWidgets('selecting a menu option fires onPreviewSpeedChanged',
      (tester) async {
    final c = EditorProjectController();
    double? picked;
    await tester.pumpWidget(_host(
      controller: c,
      previewPlaybackSpeed: 1.0,
      onPreviewSpeedChanged: (s) => picked = s,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1×'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2×'));
    await tester.pumpAndSettle();

    expect(picked, 2.0);
  });
}
