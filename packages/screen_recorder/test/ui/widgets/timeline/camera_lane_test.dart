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
              onCameraChanged: (_, __) {},
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
}
