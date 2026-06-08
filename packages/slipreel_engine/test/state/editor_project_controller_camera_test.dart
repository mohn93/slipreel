import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  CameraRegion region({double cx = 0.8}) => CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        centerX: cx,
        centerY: 0.8,
        size: 0.22,
      );

  group('EditorProjectController camera mutators', () {
    test('setCameraSettings replaces the look', () {
      final c = EditorProjectController();
      c.setCameraSettings(const CameraSettings(shape: CameraShape.vertical));
      expect(c.current.cameraSettings.shape, CameraShape.vertical);
    });

    test('add / update / remove / replace camera regions', () {
      final c = EditorProjectController();
      c.addCameraRegion(region());
      expect(c.current.cameraRegions, hasLength(1));

      c.updateCameraRegionAt(0, region(cx: 0.1));
      expect(c.current.cameraRegions.single.centerX, 0.1);

      c.replaceCameraRegions([region(cx: 0.2), region(cx: 0.3)]);
      expect(c.current.cameraRegions, hasLength(2));

      c.removeCameraRegionAt(0);
      expect(c.current.cameraRegions.single.centerX, 0.3);
    });

    test('out-of-range update/remove are no-ops', () {
      final c = EditorProjectController();
      c.addCameraRegion(region());
      c.updateCameraRegionAt(5, region(cx: 0.1)); // ignored
      c.removeCameraRegionAt(-1); // ignored
      expect(c.current.cameraRegions, hasLength(1));
    });

    test('zoom mutators preserve existing camera regions (and vice versa)', () {
      final c = EditorProjectController();
      c.addCameraRegion(region()); // camera lane now has 1 region
      // A zoom edit must NOT wipe the camera lane.
      c.addZoom(ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      ));
      expect(c.current.cameraRegions, hasLength(1),
          reason: 'addZoom must preserve camera regions');
      c.updateZoomAt(0, c.current.zoomRegions.first);
      expect(c.current.cameraRegions, hasLength(1),
          reason: 'updateZoomAt must preserve camera regions');
      c.removeZoomAt(0);
      expect(c.current.cameraRegions, hasLength(1),
          reason: 'removeZoomAt must preserve camera regions');
      // Symmetric: a camera edit must preserve the zoom region too.
      c.addZoom(ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      ));
      c.addCameraRegion(region(cx: 0.3));
      expect(c.current.zoomRegions, hasLength(1),
          reason: 'addCameraRegion must preserve zoom regions');
    });
  });
}
