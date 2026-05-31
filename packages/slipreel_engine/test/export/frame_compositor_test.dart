import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameCompositor', () {
    test('totalSize equals videoSize when frame is "None"', () {
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
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

    test('totalSize includes uniform padding for a framed clip (auto aspect)', () {
      // 320×240 + EdgeInsets.all(30) uniform padding:
      // width = 320 + 30 + 30 = 380, height = 240 + 30 + 30 = 300.
      // (Already even — yuv420p happy.)
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
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
      expect(compositor.totalSize, const Size(380, 300));
    });

    test('totalSize rounds up to even for yuv420p compatibility', () {
      // Pick padding that produces an odd dimension before rounding.
      // 320×240 + EdgeInsets.all(15.7) uniform:
      // raw total = (320 + 15.7 + 15.7, 240 + 15.7 + 15.7)
      //           = (351.4, 271.4) → rounds to (352, 271) → (352, 272)
      // after the even-up step.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
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

    test('totalSize honors OutputAspect.vertical9x16 (canvas grows vertically)', () {
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          outputAspect: OutputAspect.vertical9x16,
          windowFrame: const WindowFrame(
            name: 'Custom',
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
        videoSize: const Size(1920, 1080),
        fps: 30,
      );
      expect(compositor.totalSize.width, 1920);
      // 1920 / (9/16) = 3413.33 → rounded to nearest even: 3412 or 3414.
      expect(
        [3412, 3414].contains(compositor.totalSize.height.toInt()),
        isTrue,
        reason: 'Expected even-rounded 1920/(9/16) ≈ 3413, got '
            '${compositor.totalSize.height}',
      );
    });

    test('compose returns RGBA bytes sized to totalSize', () async {
      // Synthetic single-color BGRA video frame: solid magenta
      // (255, 0, 255). RGBA output should reproduce that pixel inside
      // the framed video region.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
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

    test('compose with a "None"-frame zoom region centers the focal at '
        'totalSize.center', () async {
      // Zoom 2× pinned to the right half of the video. With a None
      // frame totalSize == videoSize, so the focal in the zoomed
      // output should land at totalSize.center. This is a weak test
      // (we can't read individual pixels precisely after the matrix
      // transform), but it confirms the zoom path doesn't throw and
      // the focal pipeline produces a non-empty output.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
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
      expect(
        rgba[i + 0],
        greaterThan(rgba[i + 2]),
        reason: 'R should dominate B at the focal center',
      );
    });

    test(
      'compose with motionBlur=1 still returns RGBA bytes sized to totalSize',
      () async {
        // Smoke test for the screen-blur saveLayer + ImageFilter wrap.
        // We don't pixel-assert the blur (that's covered by the
        // helper unit tests) — we just confirm the wrapped path
        // produces a buffer of the right length and doesn't throw.
        final compositor = FrameCompositor(
          projectState: EditorProjectState.defaults().copyWith(
            motionBlur: 1.0,
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
        // First frame seeds the velocity tracker (zero velocity → no
        // ImageFilter wrap). Second frame at non-zero position would
        // see zero translation (no zoom in this fixture) → still no
        // wrap. Either way: no crash, buffer of expected length.
        final rgba0 = await compositor.compose(
          videoFrameBgra: magenta,
          position: Duration.zero,
        );
        final rgba1 = await compositor.compose(
          videoFrameBgra: magenta,
          position: const Duration(milliseconds: 33),
        );
        expect(rgba0.length, 8 * 4 * 4);
        expect(rgba1.length, 8 * 4 * 4);
      },
    );

    test(
      'compose with motionBlur=1 and a zooming pan produces a valid buffer',
      () async {
        // Drives the saveLayer + ImageFilter branch by giving the
        // compositor a zoom region whose focal pans across consecutive
        // frames — that produces a non-zero translation velocity, which
        // lights up screenBlurSigma. Test asserts the wrapped path
        // doesn't throw and produces a buffer of the right length.
        final zoom = ZoomRegion(
          rect: const Rect.fromLTWH(160, 120, 80, 60),
          startTime: Duration.zero,
          duration: const Duration(milliseconds: 500),
          zoomLevel: 2.0,
        );
        final compositor = FrameCompositor(
          projectState: EditorProjectState.defaults().copyWith(
            motionBlur: 1.0,
            zoomRegions: [zoom],
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

        final magenta = _solidBgra(320, 240, 0xFF, 0x00, 0xFF);
        // First frame seeds the velocity tracker (zero velocity).
        final r0 = await compositor.compose(
          videoFrameBgra: magenta,
          position: const Duration(milliseconds: 100),
        );
        // Second frame: by milliseconds 200, the zoom is mid-ramp so the
        // translation has changed between the two calls — velocity is
        // non-zero, screenBlurSigma is non-zero, and saveLayer fires.
        final r1 = await compositor.compose(
          videoFrameBgra: magenta,
          position: const Duration(milliseconds: 200),
        );
        expect(r0.length, 320 * 240 * 4);
        expect(r1.length, 320 * 240 * 4);
      },
    );

    test(
      'follow-cursor zoom: scene-blur translation at region entry is small '
      '(spring-camera focal, not raw cursor snap)',
      () {
        // Discriminating setup: the zoom rect is centred at videoSize.center
        // (160, 120) — exactly where _sceneSampleAt returns for timestamps
        // outside the region ("no active zoom → videoSize.center"). This
        // means the spring camera starts at rect.center = (160, 120) on the
        // very first frame, which matches the "prev" sample (outside the
        // region). Consequently the DeterministicFocalTrack path produces a
        // near-zero entry translation.
        //
        // With the OLD raw-cursor code _sceneSampleAt(regionStart) would
        // instead use cursorAtFiltered, which reads the cursor that jumped
        // to (270, 120) — 110 px away — and the translation would hit
        // sceneBlurMaxTranslation (60 px). The test asserts the spring-
        // camera path stays well under 30 px, which the raw-cursor path
        // cannot satisfy.
        const videoSize = Size(320.0, 240.0);
        // Rect centred at videoSize.center (160, 120) so that the spring's
        // init snap lands at the same point as the "outside region" focal.
        const zoomRect = Rect.fromLTWH(80, 60, 160, 120); // centre = (160,120)
        const regionStart = Duration(milliseconds: 500);
        const regionDuration = Duration(milliseconds: 800);

        // Cursor sits at centre until just before the region, then jumps
        // to (270, 120) — a 110 px step — right at the region boundary.
        final recording = CursorRecording();
        for (var ms = 0; ms <= 498; ms += 16) {
          recording.addPosition(CursorPosition(
            x: 160,
            y: 120,
            timestampMicros: ms * 1000,
          ));
        }
        // The large jump arrives exactly at region start.
        for (var ms = 500; ms <= 1400; ms += 16) {
          recording.addPosition(CursorPosition(
            x: 270,
            y: 120,
            timestampMicros: ms * 1000,
          ));
        }

        final zoomRegion = ZoomRegion(
          rect: zoomRect,
          startTime: regionStart,
          duration: regionDuration,
          zoomLevel: 2.0,
          followCursor: true,
          enterDuration: const Duration(milliseconds: 300),
          exitDuration: const Duration(milliseconds: 300),
        );

        final compositor = FrameCompositor(
          projectState: EditorProjectState.defaults().copyWith(
            motionBlur: 1.0,
            screenMovementBlur: 1.0,
            zoomRegions: [zoomRegion],
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
          cursorRecording: recording,
          metadata: _meta(),
          videoSize: videoSize,
          fps: 30,
        );

        // Signal at the first frame inside the zoom region.
        // With DeterministicFocalTrack: spring initialises at rect.center
        // = (160, 120), identical to the "prev" outside-region focal →
        // delta ≈ 0 → translation is tiny (< 5 px).
        // With raw cursor: current focal = (270, 120), prev focal =
        // (160, 120) → delta = 110 px → clamped to sceneBlurMaxTranslation
        // (60 px). The 30 px bound cleanly distinguishes the two paths.
        final signal = compositor.sceneMotionSignalAt(regionStart);

        expect(
          signal.translation.distance,
          lessThan(30.0),
          reason:
              'Scene-blur translation at zoom entry must be small when the '
              'focal tracks the spring camera (DeterministicFocalTrack), not '
              'the raw cursor which snaps 110 px in one frame.',
        );
      },
    );
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

