import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/camera_frame_source.dart';

void main() {
  Uint8List frame(int tag) => Uint8List.fromList([tag, tag, tag, 255]);

  Stream<Uint8List> streamOf(List<int> tags) async* {
    for (final t in tags) {
      yield frame(t);
    }
  }

  test('aligns output time to the camera frame index (no offset)', () async {
    // fps=10 => frameDur=100ms. tags are camera frames at indexes 0..4.
    final src = CameraFrameSource(
      frames: streamOf([0, 1, 2, 3, 4]),
      fps: 10,
      offsetMicros: 0,
    );
    expect(await src.frameAt(const Duration(milliseconds: 0)), frame(0));
    // round(250000*10/1e6)=round(2.5)=3 -> index 3
    expect(await src.frameAt(const Duration(milliseconds: 250)), frame(3));
    expect(await src.frameAt(const Duration(milliseconds: 400)), frame(4));
    await src.dispose();
  });

  test('applies the offset and clamps before-start / after-end to null',
      () async {
    // offsetMicros=200000 (200ms) => offsetFrames=round(200000*10/1e6)=2 at fps=10.
    // cameraIndex = round(t_micros*10/1e6) - 2.
    final src = CameraFrameSource(
      frames: streamOf([10, 11, 12]),
      fps: 10,
      offsetMicros: 200000,
    );
    expect(await src.frameAt(const Duration(milliseconds: 0)), isNull); // idx -2
    expect(await src.frameAt(const Duration(milliseconds: 200)), frame(10)); // idx 0
    expect(await src.frameAt(const Duration(milliseconds: 400)), frame(12)); // idx 2
    expect(await src.frameAt(const Duration(milliseconds: 600)), isNull); // exhausted (idx 4, stream only has 3)
    await src.dispose();
  });

  test('monotonic advance never rewinds (returns current frame for an earlier time)',
      () async {
    final src = CameraFrameSource(frames: streamOf([0, 1, 2]), fps: 10, offsetMicros: 0);
    expect(await src.frameAt(const Duration(milliseconds: 200)), frame(2));
    // a forward-only stream can't rewind → returns the current (last-advanced) frame
    expect(await src.frameAt(const Duration(milliseconds: 0)), frame(2));
    await src.dispose();
  });
}
