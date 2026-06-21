// packages/slipreel_engine/test/models/window_frame_device_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';

void main() {
  test('defaults: no device frame, adjustSize true', () {
    final f = WindowFrame.none();
    expect(f.deviceFrameId, isNull);
    expect(f.deviceFrameColor, isNull);
    expect(f.deviceFrameAdjustSize, isTrue);
  });

  test('copyWith sets and clears device frame', () {
    final set = WindowFrame.none()
        .copyWith(deviceFrameId: 'iphone-16-pro', deviceFrameColor: 'black');
    expect(set.deviceFrameId, 'iphone-16-pro');
    final cleared = set.copyWith(clearDeviceFrame: true);
    expect(cleared.deviceFrameId, isNull);
    expect(cleared.deviceFrameColor, isNull);
  });

  test('json round-trips device-frame fields', () {
    final f = WindowFrame.none().copyWith(
      deviceFrameId: 'iphone-16-pro',
      deviceFrameColor: 'white',
      deviceFrameAdjustSize: false,
    );
    final back = WindowFrame.fromJson(f.toJson());
    expect(back.deviceFrameId, 'iphone-16-pro');
    expect(back.deviceFrameColor, 'white');
    expect(back.deviceFrameAdjustSize, isFalse);
    expect(back, f);
  });

  test('legacy json (no device fields) loads with defaults', () {
    final json = WindowFrame.none().toJson()..remove('deviceFrameId')
      ..remove('deviceFrameColor')..remove('deviceFrameAdjustSize');
    final back = WindowFrame.fromJson(json);
    expect(back.deviceFrameId, isNull);
    expect(back.deviceFrameAdjustSize, isTrue);
  });
}
