@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';
import 'package:screen_recorder/ui/widgets/timeline/zoom_lane.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

/// Pill drags used to push a full project-state commit on EVERY pointer
/// move — each tick rebuilt every project watcher (canvas, inspector,
/// all lanes) at drag rate. The pill now previews its dragged geometry
/// locally and commits exactly once on release.
void main() {
  const pixelsPerSecond = 20.0;
  const laneWidth = 400.0;

  ZoomRegion regionAt(Duration start, Duration duration) => ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 1920, 1080),
        startTime: start,
        duration: duration,
        zoomLevel: 2.0,
      );

  Future<void> pumpLane(
    WidgetTester tester,
    List<ZoomRegion> regions, {
    required void Function(int, ZoomRegion) onZoomChanged,
  }) async {
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
                onZoomChanged: onZoomChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Rect pillRect(WidgetTester tester, int index) =>
      tester.getRect(find.byKey(ValueKey('zoom-pill-body-$index')));

  testWidgets('body drag previews locally and commits once on release',
      (tester) async {
    final changes = <(int, ZoomRegion)>[];
    // One region at 5s-7s → x 100-140 at 20 px/s.
    final regions = [regionAt(const Duration(seconds: 5), const Duration(seconds: 2))];
    await pumpLane(tester, regions, onZoomChanged: (i, z) => changes.add((i, z)));
    await tester.pumpAndSettle();
    final startLeft = pillRect(tester, 0).left;
    expect(startLeft, closeTo(100, 0.01));

    final gesture =
        await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('zoom-pill-body-0'))));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();

    expect(changes, isEmpty,
        reason: 'no project commit may happen while the pointer is down — '
            'per-tick commits rebuilt the whole editor at drag rate');
    expect(pillRect(tester, 0).left, greaterThan(startLeft + 10),
        reason: 'the pill must preview its dragged position locally');

    await gesture.up();
    await tester.pump();

    expect(changes, hasLength(1),
        reason: 'exactly one commit on release');
    expect(changes.single.$1, 0);
    expect(changes.single.$2.startTime, greaterThan(const Duration(seconds: 5)));
    expect(changes.single.$2.duration, const Duration(seconds: 2),
        reason: 'a body drag translates; it must not resize');
  });

  testWidgets('an aborted drag (release without net movement) commits nothing '
      'destructive and pill snaps to committed state', (tester) async {
    final changes = <(int, ZoomRegion)>[];
    final regions = [regionAt(const Duration(seconds: 5), const Duration(seconds: 2))];
    await pumpLane(tester, regions, onZoomChanged: (i, z) => changes.add((i, z)));
    await tester.pumpAndSettle();

    // Tap (press + release with no movement) — must not commit a change.
    await tester.tap(find.byKey(const ValueKey('zoom-pill-body-0')));
    await tester.pump();
    expect(changes, isEmpty);
    expect(pillRect(tester, 0).left, closeTo(100, 0.01));
  });
}
