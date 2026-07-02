import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  ZoomRegion base() => ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2,
      );

  test('defaults to none movement', () {
    expect(base().movement.kind, ZoomMovementKind.none);
  });

  test('copyWith sets the movement', () {
    final r = base().copyWith(
        movement: const ZoomMovement(kind: ZoomMovementKind.pushIn));
    expect(r.movement.kind, ZoomMovementKind.pushIn);
  });

  test('copyWith without movement preserves it', () {
    final r = base()
        .copyWith(movement: const ZoomMovement(kind: ZoomMovementKind.sweep))
        .copyWith(zoomLevel: 3);
    expect(r.movement.kind, ZoomMovementKind.sweep);
  });

  test('json round-trips the movement', () {
    final r = base().copyWith(
        movement: const ZoomMovement(
            kind: ZoomMovementKind.drift,
            intensity: ZoomMovementIntensity.dramatic));
    final back = ZoomRegion.fromJson(r.toJson());
    expect(back.movement, r.movement);
  });

  test('legacy json without a movement key loads as none', () {
    final json = base().toJson()..remove('movement');
    expect(ZoomRegion.fromJson(json).movement.kind, ZoomMovementKind.none);
  });

  test('movement participates in == / hashCode', () {
    final a = base().copyWith(
        movement: const ZoomMovement(kind: ZoomMovementKind.pushIn));
    final b = base().copyWith(
        movement: const ZoomMovement(kind: ZoomMovementKind.sweep));
    expect(a == b, isFalse);
    expect(a.hashCode == b.hashCode, isFalse);
  });
}
