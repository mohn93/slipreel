@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';
import 'package:screen_recorder/ui/widgets/timeline/zoom_lane.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

/// Regression guard for short zoom pills swallowing their neighbour.
///
/// The pill's rendered width was floored at `handleHitWidth * 2` (32px)
/// unconditionally. Regions that abut exactly still occur — manual
/// placement can drag one region flush against the next, and the fixture
/// below constructs the case directly — so once a second maps to fewer
/// than 32px — roughly 30s of recording at 1x — the earlier pill rendered
/// wider than its own duration and spilled over its neighbour. (Auto
/// detection no longer produces exact abutment itself: it now merges any
/// seam a truncate would have created rather than truncating, so this is
/// a manual-placement and short-region guard rather than an auto-detection
/// one.) Pills are stacked in ascending order, so the later pill paints
/// on top and its opaque gesture detector intercepts events: the earlier
/// region's right-edge resize handle and delete button, both positioned off
/// the inflated box, land inside the neighbour and become unreachable.
///
/// The floor is now capped at the distance to the next region's left edge.
void main() {
  // 1s -> 20px, i.e. below the 32px floor: exactly the regime the bug needs.
  const pixelsPerSecond = 20.0;
  const laneWidth = 400.0;

  ZoomRegion regionAt(Duration start, Duration duration) => ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: start,
        duration: duration,
        zoomLevel: 2.0,
      );

  Future<void> pumpLane(WidgetTester tester, List<ZoomRegion> regions) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: laneWidth,
              height: laneHeight,
              child: ZoomLane(
                duration: const Duration(seconds: 20),
                pixelsPerSecond: pixelsPerSecond,
                contentWidth: laneWidth,
                zoomRegions: regions,
                clips: const [],
                onSeek: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect pillRect(WidgetTester tester, int index) =>
      tester.getRect(find.byKey(ValueKey('zoom-pill-body-$index')));

  testWidgets(
    'abutting sub-1.5s pills do not overlap at a sub-32px-per-second scale',
    (tester) async {
      await pumpLane(tester, [
        regionAt(Duration.zero, const Duration(milliseconds: 1000)),
        regionAt(const Duration(milliseconds: 1000),
            const Duration(milliseconds: 1000)),
      ]);

      final first = pillRect(tester, 0);
      final second = pillRect(tester, 1);

      // Sanity: this scale really is inside the regime the floor used to
      // inflate — 1000ms is 20px, under the 32px floor.
      expect(second.left - first.left, closeTo(20.0, 0.01));

      expect(
        first.right,
        lessThanOrEqualTo(second.left + 0.01),
        reason: 'the earlier pill must not spill over its neighbour, or its '
            'right handle and delete button become unreachable',
      );
    },
  );

  testWidgets('an isolated short pill still gets the grabbable floor',
      (tester) async {
    await pumpLane(tester, [
      regionAt(Duration.zero, const Duration(milliseconds: 1000)),
    ]);

    expect(pillRect(tester, 0).width, closeTo(handleHitWidth * 2, 0.01));
  });

  testWidgets('a short pill with room before the next region keeps the floor',
      (tester) async {
    // Next region starts 5s later: 100px of room, far more than the floor.
    await pumpLane(tester, [
      regionAt(Duration.zero, const Duration(milliseconds: 1000)),
      regionAt(const Duration(seconds: 5), const Duration(seconds: 2)),
    ]);

    expect(pillRect(tester, 0).width, closeTo(handleHitWidth * 2, 0.01));
  });
}
