import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/clip_lane.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart';

ClipSlice _slice({int cs = 0, int ce = 10, int? ts, int? te}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

Widget _harness(ClipLane lane) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 800, height: 60, child: lane)));

void main() {
  group('ClipLane multi-slice', () {
    testWidgets('renders one SliceBar per clip', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5), _slice(cs: 5, ce: 10), _slice(cs: 10, ce: 15)],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        cursorXListenable: ValueNotifier<double?>(null),
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
      )));
      expect(find.byType(SliceBar), findsNWidgets(3));
    });

    testWidgets('slice bars sit at edited-time x (visual collapse of gaps)', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5), _slice(cs: 8, ce: 12)],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        cursorXListenable: ValueNotifier<double?>(null),
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
      )));
      final bars = tester.widgetList<SliceBar>(find.byType(SliceBar)).toList();
      expect(bars.length, 2);
      expect(bars[0].editedStart, Duration.zero);
      expect(bars[1].editedStart, const Duration(seconds: 5));
    });

    testWidgets('selectedSliceIndex propagates to the right SliceBar', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5), _slice(cs: 5, ce: 10)],
        selectedSliceIndex: 1,
        pixelsPerSecond: 50,
        cursorXListenable: ValueNotifier<double?>(null),
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
      )));
      final bars = tester.widgetList<SliceBar>(find.byType(SliceBar)).toList();
      expect(bars[0].isSelected, false);
      expect(bars[1].isSelected, true);
    });

    testWidgets('SliceBar selection toggle bubbles up to onSliceSelected', (tester) async {
      int? selected;
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5), _slice(cs: 5, ce: 10)],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        cursorXListenable: ValueNotifier<double?>(null),
        onSliceSelected: (i) => selected = i,
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
      )));
      await tester.tap(find.byKey(const ValueKey('slice-bar-body')).first);
      expect(selected, 0);
    });

    testWidgets('re-tapping currently-selected slice toggles to null', (tester) async {
      int? selected = 0;
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5)],
        selectedSliceIndex: selected,
        pixelsPerSecond: 50,
        cursorXListenable: ValueNotifier<double?>(null),
        onSliceSelected: (i) => selected = i,
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
      )));
      await tester.tap(find.byKey(const ValueKey('slice-bar-body')));
      expect(selected, null);
    });

    testWidgets('seam painted between adjacent slices', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5), _slice(cs: 5, ce: 10)],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        cursorXListenable: ValueNotifier<double?>(null),
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
      )));
      expect(find.byKey(const ValueKey('clip-lane-seams')), findsOneWidget);
    });
  });
}
