// packages/slipreel_engine/test/export/frame_compositor_device_test.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

// 1206x2622 native screen; small bezel for a fast test (scaled-down,
// proportions preserved): bezel 120x240, screen inset 10px each side.
DeviceFrameCatalog _catalog() => const DeviceFrameCatalog([
      DeviceFrameEntry(
        id: 'test-phone', family: 'Test Phone', kind: 'phone',
        screenWidth: 100, screenHeight: 220,
        colors: [
          DeviceFrameColorVariant(
            id: 'black', name: 'Black', swatch: Color(0xFF000000),
            portrait: DeviceFrameOrientationAsset(
              asset: 'test://bezel-p', bezelWidth: 120, bezelHeight: 240,
              screenRect: DeviceScreenRect(
                l: 10 / 120, t: 10 / 240, r: 110 / 120, b: 230 / 240)),
            landscape: DeviceFrameOrientationAsset(
              asset: 'test://bezel-l', bezelWidth: 240, bezelHeight: 120,
              screenRect: DeviceScreenRect(
                l: 10 / 240, t: 10 / 120, r: 230 / 240, b: 110 / 120)),
          ),
        ],
      ),
    ]);

// A bezel image: fully red, with a transparent rect where the screen is.
Future<ui.Image> _bezelImage(int w, int h, Rect hole) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFFFF0000));
  c.drawRect(hole, Paint()..blendMode = BlendMode.clear);
  final pic = rec.endRecording();
  return pic.toImage(w, h);
}

Uint8List _solidBgra(int w, int h, int b, int g, int r) {
  final bytes = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    bytes[i * 4] = b; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = r; bytes[i * 4 + 3] = 255;
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('device-frame compose: video in cutout, bezel around it', () async {
    final state = EditorProjectState.defaults().copyWith(
      windowFrame: WindowFrame.none()
          .copyWith(deviceFrameId: 'test-phone', deviceFrameColor: 'black'),
    );
    final comp = FrameCompositor(
      projectState: state,
      cursorRecording: CursorRecording(),
      metadata: RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
        widthPx: 100,
        heightPx: 220,
        fps: 60,
        isDeviceCapture: true,
      ),
      videoSize: const Size(100, 220),
      fps: 60,
      deviceFrameCatalog: _catalog(),
    )..bezelImageLoaderOverride = (asset) =>
        _bezelImage(120, 240, const Rect.fromLTWH(10, 10, 100, 220));

    expect(comp.deviceFramePlan, isNotNull);
    expect(comp.totalSize.width.round(), 120);
    expect(comp.totalSize.height.round(), 240);

    final rgba = await comp.compose(
      videoFrameBgra: _solidBgra(100, 220, 0, 255, 0), // green video
      position: Duration.zero,
    );
    final w = comp.totalSize.width.round();
    int at(int x, int y) {
      final i = (y * w + x) * 4;
      return (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]; // RGB
    }
    // Screen center -> green video.
    expect(at(60, 120), 0x00FF00);
    // Bezel ring (5px in from edge) -> red.
    expect(at(5, 120), 0xFF0000);
  });

  test('device-frame plan is null when entry kind is incompatible '
      'with the recording form factor', () {
    // test-phone is a phone entry; a 200x150 (1.33 landscape) recording is
    // tablet-shaped, so the persisted phone frame must not render.
    final state = EditorProjectState.defaults().copyWith(
      windowFrame: WindowFrame.none()
          .copyWith(deviceFrameId: 'test-phone', deviceFrameColor: 'black'),
    );
    final comp = FrameCompositor(
      projectState: state,
      cursorRecording: CursorRecording(),
      metadata: RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
        widthPx: 200,
        heightPx: 150,
        fps: 60,
        isDeviceCapture: true,
      ),
      videoSize: const Size(200, 150),
      fps: 60,
      deviceFrameCatalog: _catalog(),
    );
    expect(comp.deviceFramePlan, isNull);
  });
}
