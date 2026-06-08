import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';

void main() {
  test('cameraPlacementForTest returns null in a gap and a placement inside', () {
    final regions = [
      CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      ),
    ];
    expect(
      cameraPlacementForTest(const Duration(milliseconds: 500), regions, true),
      isA<CameraPlacement>(),
    );
    expect(
      cameraPlacementForTest(const Duration(milliseconds: 1500), regions, true),
      isNull,
    );
    expect(
      cameraPlacementForTest(const Duration(milliseconds: 500), regions, false),
      isNull,
    );
  });
}
