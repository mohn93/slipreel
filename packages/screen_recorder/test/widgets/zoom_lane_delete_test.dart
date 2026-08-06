@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';
import 'package:screen_recorder/ui/widgets/timeline/zoom_lane.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

/// Regression guard: deleting one zoom pill must not reposition the others.
///
/// Pills used to be keyed by list index. Removing region k re-bound every
/// pill element at index >= k to the NEXT region's data, and each pill's
/// AnimatedPositioned then tweened 220ms from the old region's geometry to
/// the new one — so surviving pills visibly slid across the lane on delete.
/// Pills are now keyed by [ZoomRegion.id], which removes exactly the
/// deleted pill's element and leaves the survivors' geometry untouched.
void main() {
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
  }

  Rect pillRect(WidgetTester tester, int index) =>
      tester.getRect(find.byKey(ValueKey('zoom-pill-body-$index')));

  testWidgets('deleting the first pill must not slide the survivors',
      (tester) async {
    // Three well-separated regions: 0-2s (x 0-40), 5-7s (x 100-140),
    // 10-12s (x 200-240).
    final regions = [
      regionAt(Duration.zero, const Duration(seconds: 2)),
      regionAt(const Duration(seconds: 5), const Duration(seconds: 2)),
      regionAt(const Duration(seconds: 10), const Duration(seconds: 2)),
    ];
    await pumpLane(tester, regions);
    await tester.pumpAndSettle();

    expect(pillRect(tester, 1).left, closeTo(100, 0.01));
    expect(pillRect(tester, 2).left, closeTo(200, 0.01));

    // Delete region 0 — survivors are now indices 0 (was 1) and 1 (was 2).
    await pumpLane(tester, regions.sublist(1));
    // Mid-animation frame: 110ms into the pill's 220ms position tween.
    await tester.pump(const Duration(milliseconds: 110));

    final survivorA = pillRect(tester, 0).left; // region at 5s -> should be 100
    final survivorB = pillRect(tester, 1).left; // region at 10s -> should be 200

    expect(survivorA, closeTo(100, 0.01),
        reason: 'surviving pill (5s region) must stay at x=100, '
            'not slide over from the deleted pill\'s slot');
    expect(survivorB, closeTo(200, 0.01),
        reason: 'surviving pill (10s region) must stay at x=200, '
            'not slide over from its left neighbour\'s slot');
  });
}
