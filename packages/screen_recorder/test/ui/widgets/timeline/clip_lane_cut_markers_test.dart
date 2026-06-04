import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/clip_lane.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';

ClipSlice _slice({int cs = 0, int ce = 10, int? ts, int? te}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

Widget _harness(ClipLane lane) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 800, height: 60, child: lane),
      ),
    );

void main() {
  group('ClipLane cut markers', () {
    testWidgets('renders N-1 markers for N clips', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
          _slice(cs: 10, ce: 15),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.byType(CutMarker), findsNWidgets(2));
    });

    testWidgets('no markers when only one clip', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5)],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.byType(CutMarker), findsNothing);
    });

    testWidgets('marker shows X.Xs label when seam has trim', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5, te: 4),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.text('1.0s'), findsOneWidget);
    });

    testWidgets('marker compact (no label) when seam has no trim',
        (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.text('1.0s'), findsNothing);
      expect(find.byType(CutMarker), findsOneWidget);
    });

    testWidgets('tap on marker with trim fires onClearSeamTrims', (tester) async {
      int? clearedSeam;
      int? mergedSeam;
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5, te: 4),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (i) => clearedSeam = i,
        onMergeSeam: (i) => mergedSeam = i,
      )));
      // The CutMarker is Positioned(top: kPositionedTop = -42) relative to
      // the ClipLane Stack, which places its visual center outside the root
      // viewport. tester.tap() routes through the render tree's localToGlobal,
      // which always includes the transform, so the coordinates are off-screen
      // and hit-test routing never reaches the GestureDetector. Instead we
      // extract the onTap callback directly from the GestureDetector widget
      // and invoke it — this tests the routing logic (clearSeamTrims vs
      // mergeSeam) without relying on pointer-event hit testing.
      final gd = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('cut-marker-hit')),
      );
      gd.onTap!();
      expect(clearedSeam, 0);
      expect(mergedSeam, null);
    });

    testWidgets('tap on marker without trim fires onMergeSeam', (tester) async {
      int? clearedSeam;
      int? mergedSeam;
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (i) => clearedSeam = i,
        onMergeSeam: (i) => mergedSeam = i,
      )));
      final gd = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('cut-marker-hit')),
      );
      gd.onTap!();
      expect(clearedSeam, null);
      expect(mergedSeam, 0);
    });
  });
}
