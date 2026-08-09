import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:screen_recorder/ui/widgets/timeline/camera_lane.dart';

void main() {
  CameraRegion region(int startMs, int durMs) => CameraRegion(
        startTime: Duration(milliseconds: startMs),
        duration: Duration(milliseconds: durMs),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      );

  Widget host({
    required List<CameraRegion> regions,
    int? selectedIndex,
    ValueChanged<int?>? onSelected,
    ValueChanged<int>? onDeleted,
    void Function(Duration, Duration)? onAdded,
    void Function(int, CameraRegion)? onChanged,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 64,
            child: CameraLane(
              duration: const Duration(seconds: 10),
              pixelsPerSecond: 60,
              contentWidth: 600,
              cameraRegions: regions,
              clips: const [],
              selectedIndex: selectedIndex,
              onSeek: (_) {},
              onCameraSelected: onSelected,
              onCameraDeleted: onDeleted,
              onCameraAdded: onAdded,
              onCameraChanged: onChanged ?? (_, __) {},
            ),
          ),
        ),
      );

  testWidgets('renders one pill per region', (tester) async {
    await tester.pumpWidget(host(regions: [region(0, 2000), region(3000, 2000)]));
    expect(find.byKey(const Key('camera-pill-0')), findsOneWidget);
    expect(find.byKey(const Key('camera-pill-1')), findsOneWidget);
  });

  testWidgets('tapping a pill selects it', (tester) async {
    int? selected;
    await tester.pumpWidget(host(
      regions: [region(0, 2000)],
      onSelected: (i) => selected = i,
    ));
    await tester.tap(find.byKey(const Key('camera-pill-0')));
    await tester.pump();
    expect(selected, 0);
  });

  testWidgets('body drag previews locally and commits once on release',
      (tester) async {
    // Mirrors zoom_lane_drag_commit_test.dart: per-tick onChanged
    // commits rebuilt every project watcher at drag rate; the pill now
    // previews locally and commits exactly once.
    final changes = <(int, CameraRegion)>[];
    await tester.pumpWidget(host(
      regions: [region(2000, 2000)],
      onChanged: (i, r) => changes.add((i, r)),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(const Key('camera-pill-0'))));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(changes, isEmpty,
        reason: 'no commit may happen while the pointer is down');

    await gesture.up();
    await tester.pump();
    expect(changes, hasLength(1), reason: 'exactly one commit on release');
    expect(changes.single.$2.startTime,
        greaterThan(const Duration(seconds: 2)));
    expect(changes.single.$2.duration, const Duration(seconds: 2));
  });
}
