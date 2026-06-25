import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          // Narrow box so the chip row overflows and is scrollable — the
          // condition under which off-screen chips used to bleed out.
          body: Center(
            child: SizedBox(
              width: 120,
              child: child,
            ),
          ),
        ),
      );

  testWidgets(
    'chip group clips horizontal scroll bleed but frees vertical overshoot',
    (tester) async {
      await tester.pumpWidget(host(
        InspectorChipGroup<String>(
          items: const [
            'Favorite',
            'macOS',
            'Spring',
            'Sunset',
            'Abstract',
            'Solid',
          ],
          labelOf: (s) => s,
          selected: 'macOS',
          onSelected: (_) {},
        ),
      ));

      // The fix wraps the horizontal scroll view in a ClipRect whose clipper
      // bounds the horizontal axis to the viewport width (so chips scrolled
      // off-screen are clipped instead of painting over the rail) while
      // extending the vertical axis past the strip (so the spring-hover
      // lean/scale/fly-off overshoot is NOT clipped).
      final clippers = tester
          .widgetList<ClipRect>(find.descendant(
            of: find.byType(InspectorChipGroup<String>),
            matching: find.byType(ClipRect),
          ))
          .map((c) => c.clipper)
          .whereType<CustomClipper<Rect>>();

      final matching = clippers.where((clipper) {
        final r = clipper.getClip(const Size(120, 40));
        return r.left == 0 &&
            r.right == 120 &&
            r.top < 0 &&
            r.bottom > 40;
      });

      expect(
        matching.length,
        1,
        reason: 'chip group should clip horizontal scroll bleed while '
            'leaving vertical hover overshoot unclipped',
      );
    },
  );
}
