import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker_strip.dart';

ClipSlice _slice({int cs = 0, int ce = 10, int? ts, int? te}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

Widget _harness(CutMarkerStrip strip) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 800, height: 80, child: strip),
      ),
    );

void main() {
  group('CutMarkerStrip', () {
    testWidgets('renders N-1 markers for N clips', (tester) async {
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
          _slice(cs: 10, ce: 15),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.byType(CutMarker), findsNWidgets(2));
    });

    testWidgets('no markers when only one clip', (tester) async {
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [_slice(cs: 0, ce: 5)],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.byType(CutMarker), findsNothing);
    });

    testWidgets('marker shows X.Xs label when seam has trim',
        (tester) async {
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [
          _slice(cs: 0, ce: 5, te: 4),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.text('1.0s'), findsOneWidget);
    });

    testWidgets('marker compact (no label) when seam has no trim',
        (tester) async {
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.text('1.0s'), findsNothing);
      expect(find.byType(CutMarker), findsOneWidget);
    });

    testWidgets('tap on marker with trim fires onClearSeamTrims',
        (tester) async {
      int? clearedSeam;
      int? mergedSeam;
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [
          _slice(cs: 0, ce: 5, te: 4),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (i) => clearedSeam = i,
        onMergeSeam: (i) => mergedSeam = i,
      )));
      await tester.tap(find.byType(CutMarker));
      expect(clearedSeam, 0);
      expect(mergedSeam, null);
    });

    testWidgets('tap on marker without trim fires onMergeSeam',
        (tester) async {
      int? clearedSeam;
      int? mergedSeam;
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (i) => clearedSeam = i,
        onMergeSeam: (i) => mergedSeam = i,
      )));
      await tester.tap(find.byType(CutMarker));
      expect(clearedSeam, null);
      expect(mergedSeam, 0);
    });

    testWidgets('dragging=true fades markers', (tester) async {
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
        dragging: true,
      )));
      await tester.pumpAndSettle();
      final marker = tester.widget<CutMarker>(find.byType(CutMarker));
      expect(marker.dragFade, true);
    });
  });
}
