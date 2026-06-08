import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/camera_frame_source.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // None-frame, zero padding: totalSize == videoSize, so the camera box is
  // resolved against the exact pixel grid we sample.
  const noneFrame = WindowFrame(
    name: 'None',
    padding: EdgeInsets.zero,
    cornerRadius: 0,
    shadowBlur: 0,
    shadowOffset: Offset.zero,
    shadowColor: Color(0x00000000),
    borderWidth: 0,
  );

  const videoW = 64;
  const videoH = 48;
  const camW = 16;
  const camH = 16;

  CameraFrameSource redSource() => CameraFrameSource(
        frames: Stream<Uint8List>.value(_solidBgra(camW, camH, 0x00, 0x00, 0xFF)),
        fps: 30,
        offsetMicros: 0,
      );

  EditorProjectState stateWithCamera({required bool enabled}) =>
      EditorProjectState.defaults().copyWith(
        windowFrame: noneFrame,
        // Square shape (default circle is also square-aspect, but circle would
        // clip the corners; square fills the whole box so the center reads
        // solid red).
        cameraSettings: const CameraSettings(
          enabled: true,
          shape: CameraShape.square,
          shadow: false,
          borderWidth: 0,
          mirror: false,
        ).copyWith(enabled: enabled),
        cameraRegions: [
          CameraRegion(
            startTime: Duration.zero,
            duration: const Duration(seconds: 1),
            centerX: 0.5,
            centerY: 0.5,
            size: 0.5,
          ),
        ],
      );

  test('camera PiP is painted over the screen when enabled', () async {
    final compositor = FrameCompositor(
      projectState: stateWithCamera(enabled: true),
      cursorRecording: CursorRecording(),
      metadata: _meta(),
      videoSize: Size(videoW.toDouble(), videoH.toDouble()),
      fps: 30,
      cameraFrameSource: redSource(),
      cameraOriginalAspect: camW / camH,
      cameraSrcWidth: camW,
      cameraSrcHeight: camH,
    );

    final green = _solidBgra(videoW, videoH, 0x00, 0xFF, 0x00);
    final rgba = await compositor.compose(
      videoFrameBgra: green,
      position: Duration.zero,
    );

    final w = compositor.totalSize.width.toInt();
    final h = compositor.totalSize.height.toInt();
    final cx = w ~/ 2;
    final cy = h ~/ 2;
    final i = (cy * w + cx) * 4;

    // The red camera bubble (centered, size 0.5) covers the canvas center,
    // so the center pixel must read red — proving the camera pass painted on
    // top of the green screen.
    expect(rgba[i + 0], greaterThan(200), reason: 'R high at center');
    expect(rgba[i + 1], lessThan(80), reason: 'G low at center');
    expect(rgba[i + 2], lessThan(80), reason: 'B low at center');
  });

  test('camera pass is gated off when cameraSettings.enabled == false',
      () async {
    final compositor = FrameCompositor(
      projectState: stateWithCamera(enabled: false),
      cursorRecording: CursorRecording(),
      metadata: _meta(),
      videoSize: Size(videoW.toDouble(), videoH.toDouble()),
      fps: 30,
      cameraFrameSource: redSource(),
      cameraOriginalAspect: camW / camH,
      cameraSrcWidth: camW,
      cameraSrcHeight: camH,
    );

    final green = _solidBgra(videoW, videoH, 0x00, 0xFF, 0x00);
    final rgba = await compositor.compose(
      videoFrameBgra: green,
      position: Duration.zero,
    );

    final w = compositor.totalSize.width.toInt();
    final h = compositor.totalSize.height.toInt();
    final cx = w ~/ 2;
    final cy = h ~/ 2;
    final i = (cy * w + cx) * 4;

    // No camera: the center pixel is the green video, NOT red.
    expect(rgba[i + 0], lessThan(80), reason: 'R low (not red) when disabled');
    expect(rgba[i + 1], greaterThan(200), reason: 'G high (green video)');
  });
}

RecordingMetadata _meta() => RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.now(),
      widthPx: 64,
      heightPx: 48,
      fps: 30,
    );

Uint8List _solidBgra(int w, int h, int b, int g, int r, [int a = 0xFF]) {
  final px = w * h;
  final out = Uint8List(px * 4);
  for (var i = 0; i < px; i++) {
    out[i * 4 + 0] = b;
    out[i * 4 + 1] = g;
    out[i * 4 + 2] = r;
    out[i * 4 + 3] = a;
  }
  return out;
}
