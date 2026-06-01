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
            child: TimelineScaleSlider(playheadPosition: playhead),
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

  testWidgets('tapping the "1×" reset label animates back to 1.0',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(5.0);
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();

    // Tap the reset label.
    await tester.tap(find.text('1×'));
    // Pump through the animation (200ms easeOutQuint).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(1.0, 0.01));
  });

  testWidgets('reset animation cleanup on unmount mid-animation does not throw',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(5.0);
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1×'));
    await tester.pump(); // start the animation
    await tester.pump(const Duration(milliseconds: 50)); // mid-animation
    // Unmount by pumping an empty widget tree.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    // No exception means we're good.
  });

  testWidgets('reset is no-op when already at 1.0', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();

    final beforeRef = c.current;
    await tester.tap(find.text('1×'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(identical(c.current, beforeRef), isTrue,
        reason: 'no state emit expected when already at fit');
  });

  testWidgets('tooltip waitDuration is 400ms', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.waitDuration, const Duration(milliseconds: 400));
  });
}
