import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';

void main() {
  group('Tilt3D model', () {
    test('default is flat / 2D', () {
      const t = Tilt3D();
      expect(t.style, ZoomTiltStyle.flat);
      expect(t.is3D, isFalse);
      expect(t.manualAngleX, isNull);
      expect(t.manualAngleY, isNull);
    });

    test('subtle/dramatic are 3D', () {
      expect(const Tilt3D(style: ZoomTiltStyle.subtle).is3D, isTrue);
      expect(const Tilt3D(style: ZoomTiltStyle.dramatic).is3D, isTrue);
    });

    test('json round-trips style + manual angles', () {
      const t = Tilt3D(
          style: ZoomTiltStyle.dramatic, manualAngleX: -7, manualAngleY: 3);
      expect(Tilt3D.fromJson(t.toJson()), t);
    });

    test('fromJson of empty map is flat (legacy default)', () {
      expect(Tilt3D.fromJson(const {}), const Tilt3D());
    });

    test('copyWith changes style and clears manual via flags', () {
      const t = Tilt3D(style: ZoomTiltStyle.subtle, manualAngleX: 5);
      expect(t.copyWith(style: ZoomTiltStyle.dramatic).style,
          ZoomTiltStyle.dramatic);
      expect(t.copyWith(clearManual: true).manualAngleX, isNull);
    });
  });

  group('Tilt3D.resolveAngles', () {
    test('flat resolves to zero', () {
      final a = const Tilt3D().resolveAngles(
          normalizedFocal: const Offset(1, 1), progress: 1);
      expect(a.xRad, 0);
      expect(a.yRad, 0);
    });

    test('auto direction: focal to the right yields +Y rotation, '
        'focal below yields -X rotation', () {
      final a = const Tilt3D(style: ZoomTiltStyle.subtle).resolveAngles(
          normalizedFocal: const Offset(1, 1), progress: 1);
      // yRad = +nx*max ; xRad = -ny*max
      expect(a.yRad, closeTo(kTiltSubtleMaxDeg * math.pi / 180, 1e-9));
      expect(a.xRad, closeTo(-kTiltSubtleMaxDeg * math.pi / 180, 1e-9));
    });

    test('magnitude scales linearly with progress', () {
      final full = const Tilt3D(style: ZoomTiltStyle.subtle).resolveAngles(
          normalizedFocal: const Offset(1, 0), progress: 1);
      final half = const Tilt3D(style: ZoomTiltStyle.subtle).resolveAngles(
          normalizedFocal: const Offset(1, 0), progress: 0.5);
      expect(half.yRad, closeTo(full.yRad / 2, 1e-9));
    });

    test('manual angle replaces auto per-axis (degrees), still * progress', () {
      final a = const Tilt3D(style: ZoomTiltStyle.subtle, manualAngleY: 10)
          .resolveAngles(normalizedFocal: const Offset(-1, 0), progress: 0.5);
      expect(a.yRad, closeTo(10 * math.pi / 180 * 0.5, 1e-9));
    });

    test('dramatic uses the larger max angle', () {
      final a = const Tilt3D(style: ZoomTiltStyle.dramatic).resolveAngles(
          normalizedFocal: const Offset(1, 0), progress: 1);
      expect(a.yRad, closeTo(kTiltDramaticMaxDeg * math.pi / 180, 1e-9));
    });
  });
}
