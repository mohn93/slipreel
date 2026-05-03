import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/frame_compositor.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameCompositor', () {
    test('totalSize equals videoSize when frame is "None"', () {
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyForTest(
          windowFrame: const WindowFrame(
            name: 'None',
            padding: EdgeInsets.zero,
            cornerRadius: 0,
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
      );
      expect(compositor.totalSize, const Size(320, 240));
    });

    test('totalSize includes aspect-scaled padding for a framed clip', () {
      // 320×240 → aspect 4/3. EdgeInsets.all(30) → top/bottom=30,
      // left/right = 30 * 4/3 = 40. totalSize = 320+80, 240+60 =
      // 400, 300. (Already even — yuv420p happy.)
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyForTest(
          windowFrame: const WindowFrame(
            name: 'Custom',
            padding: EdgeInsets.all(30),
            cornerRadius: 4,
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
      );
      expect(compositor.totalSize, const Size(400, 300));
    });

    test('totalSize rounds up to even for yuv420p compatibility', () {
      // Pick padding that produces an odd dimension before rounding.
      // 320×240 + EdgeInsets.all(15.7): top/bottom=15.7,
      // left/right=15.7*4/3=20.93. Raw total = (320+41.86, 240+31.4)
      // = (361.86, 271.4) → rounds to (362, 271) → (362, 272) after
      // the even-up step.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyForTest(
          windowFrame: const WindowFrame(
            name: 'Custom',
            padding: EdgeInsets.all(15.7),
            cornerRadius: 0,
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
      );
      // Width should be even.
      expect(compositor.totalSize.width.toInt().isEven, isTrue);
      expect(compositor.totalSize.height.toInt().isEven, isTrue);
    });

    test('compose returns RGBA bytes sized to totalSize', () async {
      // Synthetic single-color BGRA video frame: solid magenta
      // (255, 0, 255). RGBA output should reproduce that pixel inside
      // the framed video region.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyForTest(
          windowFrame: const WindowFrame(
            name: 'None',
            padding: EdgeInsets.zero,
            cornerRadius: 0,
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(8, 4),
        fps: 30,
      );

      final magenta = _solidBgra(8, 4, 0xFF, 0x00, 0xFF);
      final rgba = await compositor.compose(
        videoFrameBgra: magenta,
        position: Duration.zero,
      );

      // 8 × 4 × 4 bytes = 128. Even rounding leaves dims unchanged.
      expect(rgba.length, 8 * 4 * 4);
      // Pixel at (4, 2): channel order is RGBA. BGRA(255,0,255) →
      // R=0xFF, G=0x00, B=0xFF, A=0xFF. (Source's blue and red
      // swapped on the way through Flutter's bgra8888 decoder.)
      const i = (2 * 8 + 4) * 4;
      expect(rgba[i + 0], 0xFF, reason: 'R');
      expect(rgba[i + 1], 0x00, reason: 'G');
      expect(rgba[i + 2], 0xFF, reason: 'B');
      expect(rgba[i + 3], 0xFF, reason: 'A');
    });

    test(
        'compose with a "None"-frame zoom region centers the focal at '
        'totalSize.center', () async {
      // Zoom 2× pinned to the right half of the video. With a None
      // frame totalSize == videoSize, so the focal in the zoomed
      // output should land at totalSize.center. This is a weak test
      // (we can't read individual pixels precisely after the matrix
      // transform), but it confirms the zoom path doesn't throw and
      // the focal pipeline produces a non-empty output.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyForTest(
          windowFrame: const WindowFrame(
            name: 'None',
            padding: EdgeInsets.zero,
            cornerRadius: 0,
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
          zoomRegions: [
            ZoomRegion(
              rect: const Rect.fromLTWH(160, 0, 160, 240), // right half
              startTime: Duration.zero,
              duration: const Duration(seconds: 1),
              zoomLevel: 2.0,
              followCursor: false,
              enterDuration: Duration.zero,
              exitDuration: Duration.zero,
            ),
          ],
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
      );

      // Two-color BGRA: left half blue (0, 0, 255), right half red
      // (255, 0, 0). After the zoom centers on (240, 120) — the
      // center of the right half — the dominant color in the output
      // should be red.
      final frame = _twoTone(320, 240);
      final rgba = await compositor.compose(
        videoFrameBgra: frame,
        position: const Duration(milliseconds: 500),
      );

      // Sample a pixel near the center of totalSize. After 2× zoom
      // on the right half, that pixel must be red, not blue.
      const cx = 320 ~/ 2;
      const cy = 240 ~/ 2;
      final i = (cy * 320 + cx) * 4;
      expect(rgba[i + 0], greaterThan(rgba[i + 2]),
          reason: 'R should dominate B at the focal center');
    });
  });
}

RecordingMetadata _meta() => RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.now(),
      widthPx: 320,
      heightPx: 240,
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

Uint8List _twoTone(int w, int h) {
  final out = Uint8List(w * h * 4);
  final mid = w ~/ 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = (y * w + x) * 4;
      if (x < mid) {
        // Left: blue → BGRA (255, 0, 0, 255)
        out[idx + 0] = 0xFF;
        out[idx + 1] = 0x00;
        out[idx + 2] = 0x00;
        out[idx + 3] = 0xFF;
      } else {
        // Right: red → BGRA (0, 0, 255, 255)
        out[idx + 0] = 0x00;
        out[idx + 1] = 0x00;
        out[idx + 2] = 0xFF;
        out[idx + 3] = 0xFF;
      }
    }
  }
  return out;
}

extension on EditorProjectState {
  EditorProjectState copyForTest({
    WindowFrame? windowFrame,
    List<ZoomRegion>? zoomRegions,
  }) {
    return EditorProjectState(
      zoomRegions: zoomRegions ?? this.zoomRegions,
      screenAnimationConfig: screenAnimationConfig,
      cursorAnimationConfig: cursorAnimationConfig,
      cursorSize: cursorSize,
      cursorStyle: cursorStyle,
      cursorClickEffect: cursorClickEffect,
      hideCursorOverlay: hideCursorOverlay,
      motionBlur: motionBlur,
      windowFrame: windowFrame ?? this.windowFrame,
    );
  }
}
