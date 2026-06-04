import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

Widget _harness(SliceBar bar) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 800, height: 60, child: bar)));

ClipSlice _slice({int cs = 0, int ce = 10, int? ts, int? te}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

void main() {
  group('SliceBar selection', () {
    testWidgets('tap on body invokes onSelectionToggle with sliceIndex', (tester) async {
      var toggled = -1;
      await tester.pumpWidget(_harness(SliceBar(
        slice: _slice(),
        sliceIndex: 2,
        isSelected: false,
        pixelsPerSecond: 50,
        editedStart: Duration.zero,
        onSelectionToggle: (i) => toggled = i,
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (_) {},
      )));
      await tester.tap(find.byKey(const ValueKey('slice-bar-body')));
      expect(toggled, 2);
    });

    testWidgets('selected bar paints with the selected fill', (tester) async {
      await tester.pumpWidget(_harness(SliceBar(
        slice: _slice(),
        sliceIndex: 0,
        isSelected: true,
        pixelsPerSecond: 50,
        editedStart: Duration.zero,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (_) {},
      )));
      final box = tester.widget<Container>(
        find.byKey(const ValueKey('slice-bar-body')),
      );
      final deco = box.decoration as BoxDecoration;
      // Body now paints a 3-stop vertical gradient (top-highlight,
      // base, bottom-shadow). The middle stop is the base body
      // colour — selected slices use clipFillTop there.
      final gradient = deco.gradient as LinearGradient;
      expect(gradient.colors[1], equals(clipFillTop));
    });
  });

  group('SliceBar trim handle drag', () {
    testWidgets('dragging right handle right invokes onTrimEndChanged with a larger value', (tester) async {
      Duration? lastTrimEnd;
      await tester.pumpWidget(_harness(SliceBar(
        slice: _slice(cs: 0, ce: 10, ts: 2, te: 6),
        sliceIndex: 0,
        isSelected: false,
        pixelsPerSecond: 50,
        editedStart: Duration.zero,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (v) => lastTrimEnd = v,
      )));
      // Right handle sits at (trimEnd - editedStart) * pixelsPerSecond = 4 * 50 = 200px.
      final handle = find.byKey(const ValueKey('slice-bar-right-handle'));
      await tester.drag(handle, const Offset(50, 0));
      // 50px / 50pxps = 1s extra -> 7s.
      expect(lastTrimEnd, const Duration(seconds: 7));
    });

    testWidgets('dragging left handle right invokes onTrimStartChanged with a larger value', (tester) async {
      Duration? lastTrimStart;
      await tester.pumpWidget(_harness(SliceBar(
        slice: _slice(cs: 0, ce: 10, ts: 2, te: 8),
        sliceIndex: 0,
        isSelected: false,
        pixelsPerSecond: 50,
        editedStart: Duration.zero,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (v) => lastTrimStart = v,
        onTrimEndChanged: (_) {},
      )));
      final handle = find.byKey(const ValueKey('slice-bar-left-handle'));
      await tester.drag(handle, const Offset(50, 0));
      expect(lastTrimStart, const Duration(seconds: 3));
    });
  });

  group('SliceBar chevron notch visibility', () {
    testWidgets('right chevron renders when isRightTrimmed', (tester) async {
      await tester.pumpWidget(_harness(SliceBar(
        slice: _slice(cs: 0, ce: 10, te: 7),
        sliceIndex: 0,
        isSelected: false,
        pixelsPerSecond: 50,
        editedStart: Duration.zero,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (_) {},
      )));
      expect(find.byKey(const ValueKey('slice-bar-right-chevron')), findsOneWidget);
      expect(find.byKey(const ValueKey('slice-bar-left-chevron')), findsNothing);
    });

    testWidgets('left chevron renders when isLeftTrimmed', (tester) async {
      await tester.pumpWidget(_harness(SliceBar(
        slice: _slice(cs: 0, ce: 10, ts: 3),
        sliceIndex: 0,
        isSelected: false,
        pixelsPerSecond: 50,
        editedStart: Duration.zero,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (_) {},
      )));
      expect(find.byKey(const ValueKey('slice-bar-left-chevron')), findsOneWidget);
      expect(find.byKey(const ValueKey('slice-bar-right-chevron')), findsNothing);
    });

    testWidgets('no chevron when untrimmed', (tester) async {
      await tester.pumpWidget(_harness(SliceBar(
        slice: _slice(),
        sliceIndex: 0,
        isSelected: false,
        pixelsPerSecond: 50,
        editedStart: Duration.zero,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (_) {},
      )));
      expect(find.byKey(const ValueKey('slice-bar-left-chevron')), findsNothing);
      expect(find.byKey(const ValueKey('slice-bar-right-chevron')), findsNothing);
    });
  });
}
