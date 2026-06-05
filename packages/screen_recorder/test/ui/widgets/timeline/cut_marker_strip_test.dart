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
        onClearStartTrim: () {},
        onClearEndTrim: () {},
      )));
      expect(find.byType(CutMarker), findsNWidgets(2));
    });

    testWidgets('no markers when only one clip', (tester) async {
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [_slice(cs: 0, ce: 5)],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
        onClearStartTrim: () {},
        onClearEndTrim: () {},
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
        onClearStartTrim: () {},
        onClearEndTrim: () {},
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
        onClearStartTrim: () {},
        onClearEndTrim: () {},
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
        onClearStartTrim: () {},
        onClearEndTrim: () {},
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
        onClearStartTrim: () {},
        onClearEndTrim: () {},
      )));
      await tester.tap(find.byType(CutMarker));
      expect(clearedSeam, null);
      expect(mergedSeam, 0);
    });

    testWidgets(
        'gap-only seam (post-deletion, no trim) routes first tap to merge',
        (tester) async {
      int? clearedSeam;
      int? mergedSeam;
      await tester.pumpWidget(_harness(CutMarkerStrip(
        // cs:0-3 then cs:5-10 → 2s source gap, but BOTH slices have
        // trim bounds equal to cut bounds (no actual trim). First click
        // must merge directly — clearing the (already-zero) trim would
        // be a no-op and strand the user.
        clips: [
          _slice(cs: 0, ce: 3),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (i) => clearedSeam = i,
        onMergeSeam: (i) => mergedSeam = i,
        onClearStartTrim: () {},
        onClearEndTrim: () {},
      )));
      await tester.tap(find.byType(CutMarker));
      expect(clearedSeam, null);
      expect(mergedSeam, 0);
    });

    testWidgets(
        'edge marker at left appears when first slice has start-trim',
        (tester) async {
      var startCleared = 0;
      await tester.pumpWidget(_harness(CutMarkerStrip(
        // clip 0 has 1s of start-trim (cutStart=0, trimStart=1).
        clips: [
          _slice(cs: 0, ce: 5, ts: 1),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
        onClearStartTrim: () => startCleared++,
        onClearEndTrim: () {},
      )));
      // One seam marker + one start edge marker.
      expect(find.byType(CutMarker), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('cut-marker-strip-start')));
      expect(startCleared, 1);
    });

    testWidgets(
        'edge marker at right appears when last slice has end-trim',
        (tester) async {
      var endCleared = 0;
      await tester.pumpWidget(_harness(CutMarkerStrip(
        // last clip has 1s of end-trim (cutEnd=10, trimEnd=9).
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10, te: 9),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
        onClearStartTrim: () {},
        onClearEndTrim: () => endCleared++,
      )));
      expect(find.byType(CutMarker), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('cut-marker-strip-end')));
      expect(endCleared, 1);
    });

    testWidgets(
        'no edge markers when outer trims are zero',
        (tester) async {
      await tester.pumpWidget(_harness(CutMarkerStrip(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
        onClearStartTrim: () {},
        onClearEndTrim: () {},
      )));
      // Only the single seam marker between the two clips — no edges.
      expect(find.byType(CutMarker), findsOneWidget);
      expect(find.byKey(const ValueKey('cut-marker-strip-start')),
          findsNothing);
      expect(find.byKey(const ValueKey('cut-marker-strip-end')),
          findsNothing);
    });

    testWidgets(
        'single-clip timeline can still show edge markers',
        (tester) async {
      var startCleared = 0;
      var endCleared = 0;
      await tester.pumpWidget(_harness(CutMarkerStrip(
        // Only one clip, trimmed on both outer edges.
        clips: [_slice(cs: 0, ce: 10, ts: 1, te: 9)],
        pixelsPerSecond: 50,
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
        onClearStartTrim: () => startCleared++,
        onClearEndTrim: () => endCleared++,
      )));
      expect(find.byType(CutMarker), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('cut-marker-strip-start')));
      await tester.tap(find.byKey(const ValueKey('cut-marker-strip-end')));
      expect(startCleared, 1);
      expect(endCleared, 1);
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
        onClearStartTrim: () {},
        onClearEndTrim: () {},
        dragging: true,
      )));
      await tester.pumpAndSettle();
      final marker = tester.widget<CutMarker>(find.byType(CutMarker));
      expect(marker.dragFade, true);
    });
  });
}
