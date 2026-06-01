import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/animated_indicator_bar.dart';

const _itemHeight = 40.0;
const _itemGap = 8.0;
const _itemCount = 7;

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('paints exactly one accent-colored rectangle', (tester) async {
    await tester.pumpWidget(_host(const AnimatedIndicatorBar(
      selectedIndex: 0,
      itemCount: _itemCount,
      itemHeight: _itemHeight,
      itemGap: _itemGap,
    )));
    final accent = AppPalette.midnight.accent;
    final containers = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((d) {
      final dec = d.decoration;
      return dec is BoxDecoration && dec.color == accent;
    });
    expect(containers.length, 1);
  });

  testWidgets('initial mount snaps to selectedIndex without animation',
      (tester) async {
    await tester.pumpWidget(_host(const AnimatedIndicatorBar(
      selectedIndex: 3,
      itemCount: _itemCount,
      itemHeight: _itemHeight,
      itemGap: _itemGap,
    )));
    final positioned = tester.widget<Positioned>(find.byType(Positioned));
    final centerY = (_itemHeight + _itemGap) * 3 + _itemHeight / 2;
    final expectedTop = centerY - (_itemHeight * 0.6) / 2;
    expect(positioned.top, closeTo(expectedTop, 0.5));
  });

  testWidgets('changing selectedIndex animates top toward the new target',
      (tester) async {
    int selected = 1;
    late StateSetter setter;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, ss) {
      setter = ss;
      return AnimatedIndicatorBar(
        selectedIndex: selected,
        itemCount: _itemCount,
        itemHeight: _itemHeight,
        itemGap: _itemGap,
      );
    })));

    final centerYFor = (int i) => (_itemHeight + _itemGap) * i + _itemHeight / 2;
    final topFor = (int i) => centerYFor(i) - (_itemHeight * 0.6) / 2;

    final startTop = tester.widget<Positioned>(find.byType(Positioned)).top;
    expect(startTop, closeTo(topFor(1), 0.5));

    setter(() => selected = 5);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final midTop = tester.widget<Positioned>(find.byType(Positioned)).top!;
    expect(midTop, greaterThan(topFor(1)));
    expect(midTop, lessThan(topFor(5)));

    await tester.pumpAndSettle();
    final endTop = tester.widget<Positioned>(find.byType(Positioned)).top;
    expect(endTop, closeTo(topFor(5), 1.5),
        reason: 'spring may overshoot then settle within tolerance');
  });

  testWidgets('selectedIndex < 0 fades opacity to 0', (tester) async {
    int selected = 2;
    late StateSetter setter;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, ss) {
      setter = ss;
      return AnimatedIndicatorBar(
        selectedIndex: selected,
        itemCount: _itemCount,
        itemHeight: _itemHeight,
        itemGap: _itemGap,
      );
    })));

    setter(() => selected = -1);
    await tester.pumpAndSettle();
    final opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 0.0);
  });
}
