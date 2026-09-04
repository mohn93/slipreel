import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  ZoomRegion region({
    Tilt3D tilt = const Tilt3D(),
    ZoomMovement movement = const ZoomMovement(),
  }) => ZoomRegion(
    rect: const Rect.fromLTWH(0, 0, 100, 100),
    startTime: Duration.zero,
    duration: const Duration(seconds: 2),
    zoomLevel: 2,
    tilt: tilt,
    movement: movement,
  );

  group('presets', () {
    test('flat is 2D with no movement', () {
      expect(ZoomLook.flat.tilt.is3D, isFalse);
      expect(ZoomLook.flat.movement.isActive, isFalse);
    });

    test('classic is subtle tilt, no movement', () {
      expect(ZoomLook.classic.tilt, const Tilt3D(style: ZoomTiltStyle.subtle));
      expect(ZoomLook.classic.movement.isActive, isFalse);
    });

    test('cinematic is subtle tilt with a subtle push-in', () {
      expect(ZoomLook.cinematic.tilt.style, ZoomTiltStyle.subtle);
      expect(ZoomLook.cinematic.movement.kind, ZoomMovementKind.pushIn);
      expect(
        ZoomLook.cinematic.movement.intensity,
        ZoomMovementIntensity.subtle,
      );
    });

    test('showcase is dramatic tilt with a subtle sweep', () {
      expect(ZoomLook.showcase.tilt.style, ZoomTiltStyle.dramatic);
      expect(ZoomLook.showcase.movement.kind, ZoomMovementKind.sweep);
      expect(
        ZoomLook.showcase.movement.intensity,
        ZoomMovementIntensity.subtle,
      );
    });

    test('every preset has a distinct name and round-trips by value', () {
      final names = ZoomLook.presets.map((p) => p.presetName).toSet();
      expect(names, hasLength(ZoomLook.presets.length));
      for (final p in ZoomLook.presets) {
        expect(p.presetName, isNotNull);
        expect(ZoomLook(tilt: p.tilt, movement: p.movement).presetName,
            p.presetName);
      }
    });

    test('a combination outside the presets has no name', () {
      const custom = ZoomLook(
        tilt: Tilt3D(style: ZoomTiltStyle.dramatic),
        movement: ZoomMovement(
          kind: ZoomMovementKind.pushIn,
          intensity: ZoomMovementIntensity.dramatic,
        ),
      );
      expect(custom.presetName, isNull);
    });

    test('manual tilt angles make a look custom', () {
      const tweaked = ZoomLook(
        tilt: Tilt3D(style: ZoomTiltStyle.subtle, manualAngleY: 3),
      );
      expect(tweaked.presetName, isNull);
    });
  });

  group('regions', () {
    test('of() reads the region tilt + movement', () {
      final r = region(
        tilt: ZoomLook.showcase.tilt,
        movement: ZoomLook.showcase.movement,
      );
      expect(ZoomLook.of(r), ZoomLook.showcase);
    });

    test('applyTo() only touches tilt + movement', () {
      final r = region();
      final out = ZoomLook.cinematic.applyTo(r);
      expect(out.tilt, ZoomLook.cinematic.tilt);
      expect(out.movement, ZoomLook.cinematic.movement);
      expect(out.rect, r.rect);
      expect(out.startTime, r.startTime);
      expect(out.duration, r.duration);
      expect(out.zoomLevel, r.zoomLevel);
      expect(out.id, r.id);
    });
  });

  group('json', () {
    test('round-trips every preset', () {
      for (final p in ZoomLook.presets) {
        expect(ZoomLook.fromJson(p.toJson()), p);
      }
    });

    test('empty json is the flat look (missing sections mean off)', () {
      expect(ZoomLook.fromJson(const {}), ZoomLook.flat);
    });
  });
}
