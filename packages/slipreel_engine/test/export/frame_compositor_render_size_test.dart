// packages/slipreel_engine/test/export/frame_compositor_render_size_test.dart
//
// Output-resolution rendering: when the export resolution is SMALLER than
// the composed canvas, rasterizing every frame at canvas size and letting
// ffmpeg's swscale throw most of the pixels away is pure waste (~7× at
// 5K→1080p). [FrameCompositor.renderSize] renders the same canvas-space
// scene through a top-level scale directly at the output size. Vector
// content (chrome, cursor, captions) rasterizes natively sharp at the
// output resolution; raster content (video, wallpaper) downscales once
// with filtered sampling instead of once per ffmpeg frame.
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

RecordingMetadata _meta() => RecordingMetadata(
  isPureSource: true,
  recordedAt: DateTime(2026),
  widthPx: 320,
  heightPx: 240,
  fps: 30,
);

const _noneFrame = WindowFrame(
  name: 'None',
  padding: EdgeInsets.zero,
  cornerRadius: 0,
  shadowBlur: 0,
  shadowOffset: Offset.zero,
  shadowColor: Color(0x00000000),
  borderWidth: 0,
);

const _paddedFrame = WindowFrame(
  name: 'Custom',
  padding: EdgeInsets.all(30),
  cornerRadius: 0,
  shadowBlur: 0,
  shadowOffset: Offset.zero,
  shadowColor: Color(0x00000000),
  borderWidth: 0,
);

// Padded frame WITH a solid wallpaper, so the parity test covers the
// wallpaper raster path (cached at renderSize, drawn via drawImageRect).
const _wallpaperFrame = WindowFrame(
  name: 'Custom',
  padding: EdgeInsets.all(30),
  cornerRadius: 0,
  shadowBlur: 0,
  shadowOffset: Offset.zero,
  shadowColor: Color(0x00000000),
  borderWidth: 0,
  wallpaperCategory: 'Solid',
  solidColor: Color(0xFF1E90FF),
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

List<int> _rgbaAt(Uint8List rgba, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return [rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('outputSize is a downscale-only hint with aspect-preserving fit', () {
    FrameCompositor make(Size? outputSize) => FrameCompositor(
      projectState: EditorProjectState.defaults().copyWith(
        windowFrame: _noneFrame,
      ),
      cursorRecording: CursorRecording(),
      metadata: _meta(),
      videoSize: const Size(320, 240),
      fps: 30,
      outputSize: outputSize,
    );
    // Upscale hint: render at canvas size, ffmpeg upscales.
    expect(make(const Size(1280, 960)).renderSize, const Size(320, 240));
    // Equal: no-op.
    expect(make(const Size(320, 240)).renderSize, const Size(320, 240));
    // Downscale with mismatched aspect (wider box): fit by height,
    // preserving the 4:3 canvas aspect — ffmpeg pads the rest, exactly
    // like force_original_aspect_ratio=decrease did on full-size frames.
    expect(make(const Size(200, 120)).renderSize, const Size(160, 120));
    // Downscale, matching aspect: exact.
    expect(make(const Size(160, 120)).renderSize, const Size(160, 120));
  });

  test(
    'renderSize output buffer is sized to renderSize, not totalSize',
    () async {
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          windowFrame: _noneFrame,
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
        outputSize: const Size(160, 120),
      );
      final rgba = await compositor.compose(
        videoFrameBgra: _solidBgra(320, 240, 0xFF, 0x00, 0xFF),
        position: Duration.zero,
      );
      expect(rgba.length, 160 * 120 * 4);
    },
  );

  test(
    'accepts downscaled decoder pixels with native logical geometry',
    () async {
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          windowFrame: _noneFrame,
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        decodedVideoSize: const Size(160, 120),
        fps: 30,
        outputSize: const Size(160, 120),
      );
      final rgba = await compositor.compose(
        videoFrameBgra: _solidBgra(160, 120, 0xFF, 0x00, 0xFF),
        position: Duration.zero,
      );
      expect(rgba.length, 160 * 120 * 4);
      expect(_rgbaAt(rgba, 160, 80, 60), [0xFF, 0x00, 0xFF, 0xFF]);
    },
  );

  test(
    'content is scaled, not cropped: video fills the render frame',
    () async {
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          windowFrame: _noneFrame,
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
        outputSize: const Size(160, 120),
      );
      final rgba = await compositor.compose(
        videoFrameBgra: _solidBgra(320, 240, 0xFF, 0x00, 0xFF), // magenta
        position: Duration.zero,
      );
      // Center and all four near-corner probes must be magenta: a cropped
      // (unscaled) render would leave everything beyond 160×120 missing,
      // and a mis-scaled one would shift the edges.
      for (final p in [
        [80, 60],
        [2, 2],
        [157, 2],
        [2, 117],
        [157, 117],
      ]) {
        final px = _rgbaAt(rgba, 160, p[0], p[1]);
        expect(px[0], greaterThan(200), reason: 'R at $p');
        expect(px[1], lessThan(50), reason: 'G at $p');
        expect(px[2], greaterThan(200), reason: 'B at $p');
      }
    },
  );

  test('padding geometry scales with the render size', () async {
    // 320×240 video + 30px padding → totalSize 380×300. At renderSize
    // 190×150 (s = 0.5) the video occupies [15,15]..[175,135]: inside is
    // video color, the padding ring (no wallpaper) stays transparent.
    final compositor = FrameCompositor(
      projectState: EditorProjectState.defaults().copyWith(
        windowFrame: _paddedFrame,
      ),
      cursorRecording: CursorRecording(),
      metadata: _meta(),
      videoSize: const Size(320, 240),
      fps: 30,
      outputSize: const Size(190, 150),
    );
    expect(compositor.totalSize, const Size(380, 300));
    final rgba = await compositor.compose(
      videoFrameBgra: _solidBgra(320, 240, 0xFF, 0x00, 0xFF),
      position: Duration.zero,
    );
    expect(rgba.length, 190 * 150 * 4);
    // Video center.
    final center = _rgbaAt(rgba, 190, 95, 75);
    expect(center[0], greaterThan(200));
    expect(center[2], greaterThan(200));
    // Padding corner: transparent (alpha 0) — scaled geometry keeps the
    // 15px ring, an unscaled render would put video pixels here.
    final corner = _rgbaAt(rgba, 190, 4, 4);
    expect(corner[3], 0, reason: 'padding ring must stay outside the video');
    // Just inside the scaled video rect.
    final inside = _rgbaAt(rgba, 190, 20, 20);
    expect(inside[0], greaterThan(200));
  });

  test(
    'explicit renderSize == totalSize is byte-identical to default',
    () async {
      // Includes a solid wallpaper so the wallpaper raster path (cached at
      // renderSize, drawn via drawImageRect) is part of the parity pin.
      FrameCompositor make({Size? outputSize}) => FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          windowFrame: _wallpaperFrame,
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
        outputSize: outputSize,
      );
      final defaultPath = make();
      final explicit = make(outputSize: const Size(380, 300));
      final frame = _solidBgra(320, 240, 0x10, 0xC0, 0x40);
      final a = await defaultPath.compose(
        videoFrameBgra: frame,
        position: Duration.zero,
      );
      final b = await explicit.compose(
        videoFrameBgra: frame,
        position: Duration.zero,
      );
      expect(a, equals(b));
      // Sanity: the wallpaper actually painted (padding corner is opaque
      // dodger blue, not transparent).
      final corner = _rgbaAt(a, 380, 4, 4);
      expect(corner[3], 0xFF);
      expect(corner[2], greaterThan(200), reason: 'solid blue wallpaper');
    },
  );

  test('wallpaper scales with the render size', () async {
    final compositor = FrameCompositor(
      projectState: EditorProjectState.defaults().copyWith(
        windowFrame: _wallpaperFrame,
      ),
      cursorRecording: CursorRecording(),
      metadata: _meta(),
      videoSize: const Size(320, 240),
      fps: 30,
      outputSize: const Size(190, 150),
    );
    final rgba = await compositor.compose(
      videoFrameBgra: _solidBgra(320, 240, 0xFF, 0x00, 0xFF),
      position: Duration.zero,
    );
    // Padding corner shows the wallpaper; video center shows the video.
    final corner = _rgbaAt(rgba, 190, 4, 4);
    expect(corner[3], 0xFF);
    expect(corner[2], greaterThan(200), reason: 'solid blue wallpaper');
    final center = _rgbaAt(rgba, 190, 95, 75);
    expect(center[0], greaterThan(200), reason: 'magenta video');
  });
}
