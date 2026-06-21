// packages/slipreel_engine/test/models/device_frame_loader_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';

void main() {
  test('debug-set catalog is returned by the cached loader', () async {
    debugSetDeviceFrameCatalog(const DeviceFrameCatalog([
      DeviceFrameEntry(
        id: 'x', family: 'X', kind: 'phone',
        screenWidth: 100, screenHeight: 200, colors: [],
      ),
    ]));
    final catalog = await loadDeviceFrameCatalog();
    expect(catalog.entryById('x'), isNotNull);
    debugSetDeviceFrameCatalog(null);
  });
}
