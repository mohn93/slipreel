// packages/slipreel_engine/test/export/frame_compositor_tilt_test.dart
//
// Discriminating test: export chrome + video both tilt under a 3D zoom region.
//
// The test renders the same padded-frame scene twice — once flat (2D) and once
// with tilt: Tilt3D(style: ZoomTiltStyle.subtle) — and asserts:
//   1. The two output buffers are NOT byte-identical (the 3D transform is
//      applied and produces different pixels).
//   2. The chrome region (padding band, which contains the shadow) is among
//      the pixels that differ — proving the chrome layer moved too, not just
//      the video.
//
// Investigation finding (Step 1 of task-8):
//   In frame_compositor.dart lines 350-357 the standard-path chrome canvas
//   already calls applyZoom(chromeCanvas) BEFORE painting the frame chrome.
//   applyZoom (lines 303-308) applies zoomTransform.storage — the full matrix
//   returned by ZoomTransformer.getTransform, which is a perspective matrix
//   when zoomRegion.tilt.is3D. Therefore NO production code change was needed:
//   the chrome already tilts coherently with the video. This test locks that
//   behavior in as a regression guard.
//
// Annotation: @TestOn('mac-os') is required because ui.PictureRecorder
// rasterization needs the macOS Flutter engine (not available on Linux).
@TestOn('mac-os')
library;

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

// Small video size keeps the test fast; padding is large enough that the
// chrome shadow occupies a distinguishable region in the output.
const _kVideoSize = Size(64.0, 48.0);
const _kPadding = EdgeInsets.all(16.0);

// The zoom region is placed off-center (upper-right quadrant of the video) so
// the normalized focal has non-zero dx/dy, giving a non-zero auto-tilt angle
// under ZoomTiltStyle.subtle. A center focal yields angle=0 and thus no
// perspective difference — the focal MUST be off-center for this test to
// discriminate.
// We use followCursor:false so the focal is fixed at rect.center, reproducible
// across runs.
ZoomRegion _zoomRegion({required Tilt3D tilt}) => ZoomRegion(
      rect: Rect.fromLTWH(
        _kVideoSize.width * 0.5, // upper-right: focal well off canvas center
        _kVideoSize.height * 0.1,
        _kVideoSize.width * 0.35,
        _kVideoSize.height * 0.35,
      ),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2.0,
      followCursor: false,
      enterDuration: Duration.zero,
      exitDuration: Duration.zero,
      tilt: tilt,
    );

// A padded frame with a visible shadow so the chrome layer has non-trivial
// pixels we can sample in the padding band.
const _kFrame = WindowFrame(
  name: 'Shadowed',
  padding: _kPadding,
  cornerRadius: 4,
  shadowBlur: 6,
  shadowOffset: Offset(0, 3),
  shadowColor: Color(0x88000000),
  borderWidth: 0,
);

RecordingMetadata _meta() => RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
      widthPx: _kVideoSize.width.toInt(),
      heightPx: _kVideoSize.height.toInt(),
      fps: 30,
    );

Uint8List _solidBgra(int w, int h, int b, int g, int r) {
  final bytes = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    bytes[i * 4 + 0] = b;
    bytes[i * 4 + 1] = g;
    bytes[i * 4 + 2] = r;
    bytes[i * 4 + 3] = 0xFF;
  }
  return bytes;
}

Future<Uint8List> _renderHoldFrame({required Tilt3D tilt}) async {
  final compositor = FrameCompositor(
    projectState: EditorProjectState.defaults().copyWith(
      windowFrame: _kFrame,
      zoomRegions: [_zoomRegion(tilt: tilt)],
    ),
    cursorRecording: CursorRecording(),
    metadata: _meta(),
    videoSize: _kVideoSize,
    fps: 30,
  );
  // Mid-hold (500 ms, well past any ramp at 0 ms enter/exit).
  final frame = _solidBgra(
    _kVideoSize.width.toInt(),
    _kVideoSize.height.toInt(),
    0xFF, 0x80, 0x00, // vivid blue (BGRA order: B=0xFF, G=0x80, R=0x00) to make pixel differences visible
  );
  return compositor.compose(
    videoFrameBgra: frame,
    position: const Duration(milliseconds: 500),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '3D-tilt export: flat and subtle-tilt frames are NOT pixel-identical',
    () async {
      final flat = await _renderHoldFrame(tilt: const Tilt3D());
      final tilted = await _renderHoldFrame(
        tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
      );

      expect(
        flat.length,
        tilted.length,
        reason: 'Both renders must produce the same canvas byte-length',
      );
      expect(flat.length, greaterThan(0));

      // Count pixels that differ between flat and 3D renders.
      var diffCount = 0;
      for (var i = 0; i < flat.length; i++) {
        if (flat[i] != tilted[i]) diffCount++;
      }

      expect(
        diffCount,
        greaterThan(0),
        reason:
            'A 3D-tilt region must produce different pixels than a flat region. '
            'If this fails, applyZoom is not being applied to the chrome/video '
            'layer or getTransform is returning the same matrix for 3D as flat.',
      );
    },
  );

  test(
    '3D-tilt export: chrome region (padding band) pixels differ between flat '
    'and subtle-tilt — the shadow tilts with the panel',
    () async {
      final flat = await _renderHoldFrame(tilt: const Tilt3D());
      final tilted = await _renderHoldFrame(
        tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
      );

      // totalSize = videoSize + 2*padding = (96, 80).
      // The padding band occupies the first 16 rows (top padding).
      // This is where the chrome shadow appears: a 3D tilt transforms the entire output canvas including its padding,
      // so the shadow (which is painted on the chrome canvas before the zoom is applied) shifts spatially with the tilt.
      // Sample across the full top-padding strip and count differing pixels.
      final totalW =
          (_kVideoSize.width + _kPadding.left + _kPadding.right).round();
      final padRows = _kPadding.top.round();

      var chromeDiffCount = 0;
      for (var row = 0; row < padRows; row++) {
        for (var col = 0; col < totalW; col++) {
          final byteOffset = (row * totalW + col) * 4;
          // RGBA: compare all 4 channels.
          for (var ch = 0; ch < 4; ch++) {
            if (flat[byteOffset + ch] != tilted[byteOffset + ch]) {
              chromeDiffCount++;
              break; // count pixel once even if multiple channels differ
            }
          }
        }
      }

      expect(
        chromeDiffCount,
        greaterThan(0),
        reason:
            'Pixels in the top-padding band (the chrome shadow region) must '
            'differ between flat and 3D renders. This proves the chrome canvas '
            'is transformed by applyZoom under a 3D region '
            '(frame_compositor.dart line 353: applyZoom(chromeCanvas)).',
      );
    },
  );

  test(
    '2D-flat export: two identical-tilt renders are pixel-identical '
    '(regression guard — flat path is byte-stable)',
    () async {
      final flat1 = await _renderHoldFrame(tilt: const Tilt3D());
      final flat2 = await _renderHoldFrame(tilt: const Tilt3D());

      expect(flat1, flat2,
          reason: 'Flat-path renders with the same inputs must be byte-identical.');
    },
  );
}
