import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/models/zoom_region.dart';

void main() {
  group('ZoomTransformer', () {
    test('should return identity matrix when no zoom is active', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 1), // Before zoom starts
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      expect(matrix, Matrix4.identity());
    });

    test('should calculate zoom transform at peak', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(200, 150, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 3), // At 0.5 progress (peak)
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // At peak, should have maximum zoom
      expect(matrix, isNot(Matrix4.identity()));

      // Scale component should reflect zoom level
      final scale = matrix.getMaxScaleOnAxis();
      expect(scale, greaterThan(1.0));
    });

    test('should apply ease-in-out curve', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(200, 150, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrixStart = transformer.getTransform(
        position: const Duration(milliseconds: 100),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      final matrixMid = transformer.getTransform(
        position: const Duration(seconds: 1),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // Scale should be less at start than at middle (ease-in-out)
      expect(
        matrixStart.getMaxScaleOnAxis(),
        lessThan(matrixMid.getMaxScaleOnAxis()),
      );
    });

    test('should center zoom on rect center', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(300, 200, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 1),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // Translation should be non-zero (centering the zoom)
      expect(matrix.getTranslation().x, isNot(0.0));
      expect(matrix.getTranslation().y, isNot(0.0));
    });
  });
}
