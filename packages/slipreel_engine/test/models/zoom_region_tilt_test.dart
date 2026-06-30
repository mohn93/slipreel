import 'dart:ui' show Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

ZoomRegion _base({Tilt3D? tilt}) => ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2,
      videoBounds: const Size(100, 100),
      tilt: tilt ?? const Tilt3D(),
    );

void main() {
  test('default tilt is flat', () {
    expect(_base().tilt, const Tilt3D());
  });

  test('tilt round-trips through json', () {
    final r = _base(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    final back = ZoomRegion.fromJson(r.toJson());
    expect(back.tilt, const Tilt3D(style: ZoomTiltStyle.subtle));
  });

  test('legacy json without tilt loads as flat', () {
    final r = _base(tilt: const Tilt3D(style: ZoomTiltStyle.dramatic));
    final json = r.toJson()..remove('tilt');
    expect(ZoomRegion.fromJson(json).tilt, const Tilt3D());
  });

  test('copyWith preserves tilt when not specified, changes when given', () {
    final r = _base(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    expect(r.copyWith(zoomLevel: 3).tilt,
        const Tilt3D(style: ZoomTiltStyle.subtle));
    expect(r.copyWith(tilt: const Tilt3D(style: ZoomTiltStyle.dramatic)).tilt,
        const Tilt3D(style: ZoomTiltStyle.dramatic));
  });

  test('equality and hashCode account for tilt', () {
    final flat = _base();
    final subtle = _base(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    expect(flat == subtle, isFalse);
    expect(flat.hashCode == subtle.hashCode, isFalse);
  });
}
