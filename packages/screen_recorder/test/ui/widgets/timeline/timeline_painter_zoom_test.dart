import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_painter.dart';

void main() {
  group('TimelinePainter zoom markers', () {
    test('should repaint when zoom regions change', () {
      final painter1 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: [],
      );

      final painter2 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(100, 100, 200, 150),
            startTime: const Duration(seconds: 2),
            duration: const Duration(seconds: 2),
            zoomLevel: 2.0,
          ),
        ],
      );

      expect(painter1.shouldRepaint(painter2), true);
    });

    test('should not repaint when zoom regions unchanged', () {
      final zoomRegions = [
        ZoomRegion(
          rect: const Rect.fromLTWH(100, 100, 200, 150),
          startTime: const Duration(seconds: 2),
          duration: const Duration(seconds: 2),
          zoomLevel: 2.0,
        ),
      ];

      final painter1 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: zoomRegions,
      );

      final painter2 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: zoomRegions,
      );

      expect(painter1.shouldRepaint(painter2), false);
    });
  });
}
