// packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';

DeviceFrameColorVariant _color(String id) => DeviceFrameColorVariant(
      id: id, name: id, swatch: const Color(0xFF000000),
      portrait: const DeviceFrameOrientationAsset(
        asset: 'p.png', bezelWidth: 1350, bezelHeight: 2760,
        screenRect: DeviceScreenRect(l: 0.05, t: 0.02, r: 0.95, b: 0.98)),
      landscape: const DeviceFrameOrientationAsset(
        asset: 'l.png', bezelWidth: 2760, bezelHeight: 1350,
        screenRect: DeviceScreenRect(l: 0.02, t: 0.05, r: 0.98, b: 0.95)),
    );

final _catalog = DeviceFrameCatalog([
  DeviceFrameEntry(
    id: 'iphone-16-pro', family: 'iPhone 16 Pro', kind: 'phone',
    screenWidth: 1206, screenHeight: 2622, colors: [_color('black'), _color('white')]),
  DeviceFrameEntry(
    id: 'ipad-pro-11', family: 'iPad Pro 11', kind: 'tablet',
    screenWidth: 1668, screenHeight: 2420, colors: [_color('silver')]),
]);

void main() {
  test('exact portrait match', () {
    expect(deviceMatchesRecording(_catalog.entryById('iphone-16-pro')!,
        const Size(1206, 2622)), isTrue);
  });

  test('exact landscape match (axes swapped)', () {
    expect(deviceMatchesRecording(_catalog.entryById('iphone-16-pro')!,
        const Size(2622, 1206)), isTrue);
  });

  test('non-matching resolution is not perfect', () {
    expect(perfectMatches(_catalog, const Size(1179, 2556)), isEmpty);
    expect(perfectMatches(_catalog, const Size(1206, 2622)).single.id, 'iphone-16-pro');
  });

  test('autoSelect returns the perfect match or null', () {
    expect(autoSelectDeviceFrame(_catalog, const Size(1206, 2622))!.id, 'iphone-16-pro');
    expect(autoSelectDeviceFrame(_catalog, const Size(800, 600)), isNull);
  });

  test('windowFrameWithAutoDeviceFrame sets id+color only when off and matched', () {
    final off = WindowFrame.none();
    final enabled = windowFrameWithAutoDeviceFrame(
        current: off, catalog: _catalog, recording: const Size(1206, 2622));
    expect(enabled.deviceFrameId, 'iphone-16-pro');
    expect(enabled.deviceFrameColor, 'black');

    // Already set -> unchanged.
    final preset = off.copyWith(deviceFrameId: 'ipad-pro-11', deviceFrameColor: 'silver');
    expect(identical(
        windowFrameWithAutoDeviceFrame(
            current: preset, catalog: _catalog, recording: const Size(1206, 2622)),
        preset), isTrue);

    // No match -> unchanged.
    expect(identical(
        windowFrameWithAutoDeviceFrame(
            current: off, catalog: _catalog, recording: const Size(800, 600)),
        off), isTrue);
  });
}
