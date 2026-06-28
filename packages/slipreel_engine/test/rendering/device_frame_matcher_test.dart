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

  group('recordingFormFactor', () {
    test('iPhone resolutions classify as phone (both orientations)', () {
      expect(recordingFormFactor(const Size(1206, 2622)),
          RecordingFormFactor.phone); // 2.17
      expect(recordingFormFactor(const Size(2622, 1206)),
          RecordingFormFactor.phone); // landscape, same
      expect(recordingFormFactor(const Size(1334, 750)),
          RecordingFormFactor.phone); // 16:9 = 1.78
    });

    test('iPad resolutions classify as tablet (both orientations)', () {
      expect(recordingFormFactor(const Size(1668, 2420)),
          RecordingFormFactor.tablet); // 1.45
      expect(recordingFormFactor(const Size(2048, 1536)),
          RecordingFormFactor.tablet); // 1.33
      expect(recordingFormFactor(const Size(1488, 2266)),
          RecordingFormFactor.tablet); // iPad mini 1.52
    });

    test('split boundary at 1.6 is inclusive for tablet', () {
      expect(recordingFormFactor(const Size(1600, 1000)),
          RecordingFormFactor.tablet); // exactly 1.6
      expect(recordingFormFactor(const Size(1601, 1000)),
          RecordingFormFactor.phone); // just over 1.6
    });

    test('degenerate size returns null', () {
      expect(recordingFormFactor(Size.zero), isNull);
      expect(recordingFormFactor(const Size(100, 0)), isNull);
    });
  });

  group('deviceFrameCompatible', () {
    final phone = _catalog.entryById('iphone-16-pro')!;
    final tablet = _catalog.entryById('ipad-pro-11')!;

    test('phone entry matches phone recording only', () {
      expect(deviceFrameCompatible(phone, const Size(1206, 2622)), isTrue);
      expect(deviceFrameCompatible(phone, const Size(1668, 2420)), isFalse);
    });

    test('tablet entry matches tablet recording only', () {
      expect(deviceFrameCompatible(tablet, const Size(1668, 2420)), isTrue);
      expect(deviceFrameCompatible(tablet, const Size(1206, 2622)), isFalse);
    });

    test('degenerate size is compatible with anything', () {
      expect(deviceFrameCompatible(phone, Size.zero), isTrue);
      expect(deviceFrameCompatible(tablet, Size.zero), isTrue);
    });
  });

  group('flexibleMatches (kind-filtered)', () {
    test('phone recording yields only phone entries', () {
      final r = flexibleMatches(_catalog, const Size(1206, 2622));
      expect(r.map((e) => e.id), ['iphone-16-pro']);
    });

    test('iPad recording yields only tablet entries', () {
      final r = flexibleMatches(_catalog, const Size(1668, 2420));
      expect(r.map((e) => e.id), ['ipad-pro-11']);
    });

    test('degenerate size yields all entries (no filtering)', () {
      final r = flexibleMatches(_catalog, Size.zero);
      expect(r.map((e) => e.id).toSet(),
          _catalog.entries.map((e) => e.id).toSet());
    });
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

  group('iPhone 14 family (1170x2532)', () {
    // In-memory catalog with iphone-16 (1179x2556) BEFORE iphone-14
    // (1170x2532) to prove appending iphone-14 preserves existing
    // auto-selections for already-shared resolutions.
    final catalog = DeviceFrameCatalog.parse('''
{"entries":[
  {"id":"iphone-16","family":"iPhone 16","kind":"phone",
   "screen":{"w":1179,"h":2556},
   "colors":[{"id":"black","name":"Black","swatch":"#1d1d1f",
     "portrait":{"asset":"a","bezel":{"w":1359,"h":2736},
       "screenRect":{"l":0.06,"t":0.03,"r":0.94,"b":0.97},"screenCornerRadius":0.15},
     "landscape":{"asset":"b","bezel":{"w":2736,"h":1359},
       "screenRect":{"l":0.03,"t":0.06,"r":0.97,"b":0.94},"screenCornerRadius":0.07}}]},
  {"id":"iphone-14","family":"iPhone 14","kind":"phone",
   "screen":{"w":1170,"h":2532},
   "colors":[{"id":"blue","name":"Blue","swatch":"#1d1d1f",
     "portrait":{"asset":"c","bezel":{"w":1350,"h":2760},
       "screenRect":{"l":0.05,"t":0.03,"r":0.95,"b":0.97},"screenCornerRadius":0.15},
     "landscape":{"asset":"d","bezel":{"w":2760,"h":1350},
       "screenRect":{"l":0.03,"t":0.05,"r":0.97,"b":0.95},"screenCornerRadius":0.07}}]}
]}''');

    test('1170x2532 perfect-matches and auto-selects iphone-14', () {
      const rec = Size(1170, 2532);
      final iphone14 = catalog.entryById('iphone-14')!;
      expect(deviceMatchesRecording(iphone14, rec), isTrue);
      expect(perfectMatches(catalog, rec).map((e) => e.id), ['iphone-14']);
      expect(autoSelectDeviceFrame(catalog, rec)?.id, 'iphone-14');
    });

    test('1170x2532 is a phone form factor, compatible with iphone-14', () {
      const rec = Size(1170, 2532);
      expect(recordingFormFactor(rec), RecordingFormFactor.phone);
      expect(deviceFrameCompatible(catalog.entryById('iphone-14')!, rec), isTrue);
    });

    test('appending iphone-14 does not steal 1179x2556 from iphone-16', () {
      // Shared-resolution guard: the earlier catalog entry still wins.
      expect(autoSelectDeviceFrame(catalog, const Size(1179, 2556))?.id, 'iphone-16');
    });
  });
}
