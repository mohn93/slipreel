// packages/slipreel_engine/test/models/device_frame_test.dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';

const _manifest = '''
{ "entries": [
  { "id": "iphone-16-pro", "family": "iPhone 16 Pro", "kind": "phone",
    "screen": { "w": 1206, "h": 2622 },
    "colors": [
      { "id": "black-titanium", "name": "Black Titanium", "swatch": "#3a3a3c",
        "portrait":  { "asset": "assets/device_frames/iphone-16-pro/black-titanium-portrait.png",
                       "bezel": { "w": 1350, "h": 2760 },
                       "screenRect": { "l": 0.0533, "t": 0.0250, "r": 0.9467, "b": 0.9750 } },
        "landscape": { "asset": "assets/device_frames/iphone-16-pro/black-titanium-landscape.png",
                       "bezel": { "w": 2760, "h": 1350 },
                       "screenRect": { "l": 0.0250, "t": 0.0533, "r": 0.9750, "b": 0.9467 } } }
    ] }
] }
''';

void main() {
  test('parses a manifest into a catalog', () {
    final catalog = DeviceFrameCatalog.parse(_manifest);
    expect(catalog.entries, hasLength(1));
    final entry = catalog.entryById('iphone-16-pro')!;
    expect(entry.family, 'iPhone 16 Pro');
    expect(entry.kind, 'phone');
    expect(entry.screenWidth, 1206);
    expect(entry.screenHeight, 2622);

    final color = entry.colorById('black-titanium')!;
    expect(color.name, 'Black Titanium');
    expect(color.swatch, const Color(0xFF3A3A3C));
    expect(color.portrait.asset, endsWith('black-titanium-portrait.png'));
    expect(color.portrait.bezelWidth, 1350);
    expect(color.portrait.bezelHeight, 2760);
    expect(color.portrait.screenRect.l, closeTo(0.0533, 1e-9));
    expect(color.landscape.bezelWidth, 2760);
  });

  test('unknown ids return null', () {
    final catalog = DeviceFrameCatalog.parse(_manifest);
    expect(catalog.entryById('nope'), isNull);
    expect(catalog.entryById('iphone-16-pro')!.colorById('gold'), isNull);
  });
}
