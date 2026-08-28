import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/frame_painter.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

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

    test(
      'totalSize includes uniform padding for a framed clip (auto aspect)',
      () {
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
      },
    );

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

    test(
      'totalSize honors OutputAspect.vertical9x16 (canvas grows vertically)',
      () {
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
          reason:
              'Expected even-rounded 1920/(9/16) ≈ 3413, got '
              '${compositor.totalSize.height}',
        );
      },
    );

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

    test(
      'trimmed-away frames cannot advance exported cursor history',
      () async {
        final recording = CursorRecording()
          ..addPosition(CursorPosition(x: 1, y: 1, timestampMicros: 0))
          ..addPosition(CursorPosition(x: 7, y: 3, timestampMicros: 3000000));
        final defaults = EditorProjectState.defaults();
        final compositor = FrameCompositor(
          projectState: defaults.copyWith(
            timeline: defaults.timeline.copyWith(
              clips: [
                ClipSlice(
                  cutStart: Duration.zero,
                  cutEnd: const Duration(seconds: 1),
                ),
                ClipSlice(
                  cutStart: const Duration(seconds: 2),
                  cutEnd: const Duration(seconds: 3),
                ),
              ],
            ),
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
          videoSize: const Size(8, 4),
          fps: 30,
        );
        final frame = _solidBgra(8, 4, 0, 0, 0);

        for (final t in [900, 1500, 2000]) {
          await compositor.compose(
            videoFrameBgra: frame,
            position: Duration(milliseconds: t),
          );
        }

        expect(
          compositor.cursorHistoryAt(const Duration(milliseconds: 1950)),
          isNull,
        );
        expect(
          compositor.cursorHistoryAt(const Duration(seconds: 2)),
          isNotNull,
        );
      },
    );

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
      'compose with max motion blur still returns RGBA bytes sized to totalSize',
      () async {
        // Smoke test for the screen-blur saveLayer + ImageFilter wrap.
        // We don't pixel-assert the blur (that's covered by the
        // helper unit tests) — we just confirm the wrapped path
        // produces a buffer of the right length and doesn't throw.
        final compositor = FrameCompositor(
          projectState: EditorProjectState.defaults().copyWith(
            motionBlur: 0.5,
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
      'compose with max motion blur and a zooming pan produces a valid buffer',
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
            motionBlur: 0.5,
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

    test('shadowed frame + zooming pan composites the crisp chrome layer '
        'separately from the blurred content (no crash, right size)', () async {
      // Exercises the chrome/content split: a non-"None" frame with a drop
      // shadow, zoomed and panning so the scene-blur path engages. The
      // shadow must be rendered on its own crisp layer (so the camera-motion
      // smear can't fade it) while the video+cursor content is blurred. We
      // can't pixel-assert the shader in a headless test, so this guards the
      // new compositing path against crashes and size regressions; the
      // visual result is verified at runtime.
      final recording = CursorRecording();
      for (var ms = 0; ms <= 800; ms += 16) {
        // Cursor drifts so the focal pans (non-zero translation → blur).
        recording.addPosition(
          CursorPosition(x: 160 + ms * 0.2, y: 120, timestampMicros: ms * 1000),
        );
      }
      final zoom = ZoomRegion(
        rect: const Rect.fromLTWH(120, 90, 80, 60),
        startTime: Duration.zero,
        duration: const Duration(milliseconds: 800),
        zoomLevel: 2.0,
        followCursor: true,
        enterDuration: const Duration(milliseconds: 300),
      );
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          motionBlur: 0.5,
          screenMovementBlur: 1.0,
          zoomRegions: [zoom],
          windowFrame: const WindowFrame(
            name: 'Shadowed',
            padding: EdgeInsets.all(24),
            cornerRadius: 12,
            shadowBlur: 18,
            shadowOffset: Offset(0, 8),
            shadowColor: Color(0x66000000),
            borderWidth: 0,
          ),
        ),
        cursorRecording: recording,
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
      );

      final magenta = _solidBgra(320, 240, 0xFF, 0x00, 0xFF);
      // First compose seeds the velocity tracker; the second lands mid-ramp
      // (300 ms enter) with a panning focal, so the blur path engages.
      await compositor.compose(
        videoFrameBgra: magenta,
        position: const Duration(milliseconds: 150),
      );
      final total = await compositor.compose(
        videoFrameBgra: magenta,
        position: const Duration(milliseconds: 200),
      );
      final canvas = FramePainter.calculateTotalSize(
        frame: const WindowFrame(
          name: 'Shadowed',
          padding: EdgeInsets.all(24),
          cornerRadius: 12,
          shadowBlur: 18,
          shadowOffset: Offset(0, 8),
          shadowColor: Color(0x66000000),
          borderWidth: 0,
        ),
        videoSize: const Size(320, 240),
      );
      expect(total.length, canvas.width.toInt() * canvas.height.toInt() * 4);
    });

    test('follow-cursor zoom: scene-blur translation at region entry is small '
        '(spring-camera focal, not raw cursor snap)', () {
      // Discriminating setup: the zoom rect is centred at videoSize.center
      // (160, 120), exactly where _sceneSampleAt returns for timestamps
      // outside the region ("no active zoom -> videoSize.center"). The
      // follow-cursor spring also starts at videoSize.center on the very
      // first frame, which matches the "prev" sample (outside the region).
      // Consequently the DeterministicFocalTrack path produces a near-zero
      // entry translation.
      //
      // With the OLD raw-cursor code _sceneSampleAt(regionStart) would
      // instead use cursorAtFiltered, which reads the cursor that jumped
      // to (270, 120) — 110 px away — and the translation would hit
      // sceneBlurMaxTranslation (60 px). The test asserts the spring-
      // camera path stays well under 30 px, which the raw-cursor path
      // cannot satisfy.
      const videoSize = Size(320.0, 240.0);
      // Rect centred at videoSize.center (160, 120); followCursor ignores
      // it for targeting, but keeping it centered preserves this test's
      // old setup while making the expected base focal explicit.
      const zoomRect = Rect.fromLTWH(80, 60, 160, 120); // centre = (160,120)
      const regionStart = Duration(milliseconds: 500);
      const regionDuration = Duration(milliseconds: 800);

      // Cursor sits at centre until just before the region, then jumps
      // to (270, 120) — a 110 px step — right at the region boundary.
      final recording = CursorRecording();
      for (var ms = 0; ms <= 498; ms += 16) {
        recording.addPosition(
          CursorPosition(x: 160, y: 120, timestampMicros: ms * 1000),
        );
      }
      // The large jump arrives exactly at region start.
      for (var ms = 500; ms <= 1400; ms += 16) {
        recording.addPosition(
          CursorPosition(x: 270, y: 120, timestampMicros: ms * 1000),
        );
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
          motionBlur: 0.5,
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
      // With DeterministicFocalTrack: spring initialises at video center
      // (160, 120), identical to the "prev" outside-region focal ->
      // delta ~= 0 -> translation is tiny (< 5 px).
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
    });

    test('edge-cursor zoom: post-ramp scene-blur translation is ~0 (no phantom '
        'smear from the focal running past the visible clamp)', () {
      // Repro for "flickers on zoom, fine once it settles". The camera
      // zooms onto a cursor near the screen corner. The VISIBLE focal is
      // clamped to what 2x can frame (maxX=1440, maxY=810 on 1920x1080),
      // but the spring controller's focal keeps chasing the RAW cursor
      // (1900,1050) past that clamp once the enter ramp ends. Scene-blur
      // translation is derived from the camera focal; reading the raw
      // (unclamped) focal smears by motion that never reaches the screen —
      // a phantom trail over an image that is already pinned at the edge.
      // The blur must measure the VISIBLE (clamped) focal, so during the
      // post-ramp settle the translation is ~0.
      const videoSize = Size(1920, 1080);
      const zoomRect = Rect.fromLTWH(760, 340, 400, 400); // center (960,540)

      // Cursor parked at the far corner for the whole timeline — beyond
      // what 2x can frame, so the visible camera pins at the clamp.
      final recording = CursorRecording();
      for (var ms = 0; ms <= 3000; ms += 16) {
        recording.addPosition(
          CursorPosition(x: 1900, y: 1050, timestampMicros: ms * 1000),
        );
      }

      final zoomRegion = ZoomRegion(
        rect: zoomRect,
        startTime: Duration.zero,
        duration: const Duration(milliseconds: 3000),
        zoomLevel: 2.0,
        followCursor: true,
        followMode: FollowMode.centered,
        enterDuration: const Duration(milliseconds: 300),
        exitDuration: Duration.zero,
        followDuration: const Duration(milliseconds: 400),
      );

      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          motionBlur: 0.5,
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

      // 300 ms into the hold (the 300 ms enter ramp has ended): the spring
      // is still sliding the raw focal 1440->1900 toward the cursor, but
      // the visible camera is static at the clamp (1440,810). Both `cur`
      // and `prev` sit in this post-ramp window, so a visible-focal signal
      // is ~0 while a raw-focal signal hits the translation cap.
      final signal = compositor.sceneMotionSignalAt(
        const Duration(milliseconds: 600),
      );

      expect(
        signal.translation.distance,
        lessThan(2.0),
        reason:
            'post-ramp translation must be ~0 — the visible (clamped) '
            'camera is static; smearing by the raw focal past the clamp is '
            'the phantom that flickers as the zoom settles',
      );
    });

    test('_loadWallpaperPhoto disposes the codec after decoding the '
        'frame', () async {
      // Guards the codec leak fix: the success path must dispose the
      // codec once a frame is decoded. A regression (dropping the
      // dispose) leaves spy.disposed false.
      final compositor = _wallpaperCompositor();
      final image = await _make1x1Image();
      final spy = _SpyCodec(image);
      compositor.wallpaperCodecFactoryOverride =
          (assetPath, targetWidth) async => spy;

      final photo = await compositor.debugLoadWallpaperPhoto('macOS', 0);

      expect(photo, isNotNull, reason: 'macOS is a photo category');
      expect(spy.getNextFrameCalls, 1);
      expect(
        spy.disposed,
        isTrue,
        reason: 'codec must be disposed after a successful decode',
      );
      // `photo` is the same instance the spy frame returned; dispose once.
      photo?.dispose();
    });

    test(
      'wallpaper photo decode targets render width, not source canvas',
      () async {
        final compositor = _wallpaperCompositor(outputSize: const Size(4, 2));
        final image = await _make1x1Image();
        final spy = _SpyCodec(image);
        int? requestedWidth;
        compositor.wallpaperCodecFactoryOverride =
            (assetPath, targetWidth) async {
              requestedWidth = targetWidth;
              return spy;
            };

        final photo = await compositor.debugLoadWallpaperPhoto('macOS', 0);
        expect(requestedWidth, 4);
        photo?.dispose();
      },
    );

    test('visible chrome reaches the composed bytes (opaque vs transparent '
        'shadow differ)', () async {
      // Guards the chrome compositing step itself: if a refactor drops
      // the chrome layer from the output, both composes below produce
      // identical bytes and this fails. Same frame geometry both times
      // so totalSize is identical; only the chrome's visibility changes.
      Future<Uint8List> composeWithShadow(int shadowArgb) async {
        final compositor = FrameCompositor(
          projectState: EditorProjectState.defaults().copyWith(
            windowFrame: WindowFrame(
              name: 'ChromeGuard',
              padding: const EdgeInsets.all(24),
              cornerRadius: 12,
              shadowBlur: 18,
              shadowOffset: const Offset(0, 8),
              shadowColor: Color(shadowArgb),
              borderWidth: 0,
            ),
          ),
          cursorRecording: CursorRecording(),
          metadata: _meta(),
          videoSize: const Size(32, 24),
          fps: 30,
        );
        try {
          return await compositor.compose(
            videoFrameBgra: _solidBgra(32, 24, 0xFF, 0x00, 0xFF),
            position: Duration.zero,
          );
        } finally {
          compositor.dispose();
        }
      }

      final withShadow = await composeWithShadow(0xAA000000);
      final withoutShadow = await composeWithShadow(0x00000000);
      expect(withShadow.length, withoutShadow.length);
      var differ = false;
      for (var i = 0; i < withShadow.length && !differ; i++) {
        differ = withShadow[i] != withoutShadow[i];
      }
      expect(
        differ,
        isTrue,
        reason:
            'an opaque drop shadow must change the composed pixels; '
            'identical bytes mean the chrome layer was dropped',
      );
    });

    test('scene motion blur reaches the composed bytes (blur on vs off '
        'differ mid-pan)', () async {
      // Guards the blur compositing step: if a refactor stops routing
      // the smeared content into the output, the blur-on sequence
      // produces the same bytes as blur-off and this fails.
      Future<Uint8List> composeSequence({required double motionBlur}) async {
        final recording = CursorRecording();
        for (var ms = 0; ms <= 800; ms += 16) {
          recording.addPosition(
            CursorPosition(
              x: 160 + ms * 0.2,
              y: 120,
              timestampMicros: ms * 1000,
            ),
          );
        }
        final compositor = FrameCompositor(
          projectState: EditorProjectState.defaults().copyWith(
            motionBlur: motionBlur,
            screenMovementBlur: 1.0,
            zoomRegions: [
              ZoomRegion(
                rect: const Rect.fromLTWH(120, 90, 80, 60),
                startTime: Duration.zero,
                duration: const Duration(milliseconds: 800),
                zoomLevel: 2.0,
                followCursor: true,
                enterDuration: const Duration(milliseconds: 300),
              ),
            ],
            windowFrame: const WindowFrame(
              name: 'BlurGuard',
              padding: EdgeInsets.all(24),
              cornerRadius: 12,
              shadowBlur: 0,
              shadowOffset: Offset.zero,
              shadowColor: Color(0x00000000),
              borderWidth: 0,
            ),
          ),
          cursorRecording: recording,
          metadata: _meta(),
          videoSize: const Size(320, 240),
          fps: 30,
        );
        try {
          final magenta = _solidBgra(320, 240, 0xFF, 0x00, 0xFF);
          await compositor.compose(
            videoFrameBgra: magenta,
            position: const Duration(milliseconds: 150),
          );
          return await compositor.compose(
            videoFrameBgra: magenta,
            position: const Duration(milliseconds: 200),
          );
        } finally {
          compositor.dispose();
        }
      }

      // Both sequences flow through the module-level cached
      // FragmentShader (reused across paints and compositors). Byte
      // determinism here doubles as the reuse pin: every uniform and the
      // sampler must be re-set per call, so a frame's bytes cannot
      // depend on what the shader painted previously. The second
      // blurred run reproduces the first byte-for-byte even though the
      // shader painted different (crisp-path skipped) frames in
      // between.
      // Use the actual product maximum. A former version tested 1.0 even
      // though the UI and persisted project state cap this control at 0.5,
      // allowing an invisible-in-production calibration to pass.
      final blurred = await composeSequence(motionBlur: 0.5);
      final crisp = await composeSequence(motionBlur: 0.0);
      final blurredAgain = await composeSequence(motionBlur: 0.5);
      expect(
        blurredAgain,
        equals(blurred),
        reason: 'reused shader must not carry state between frames',
      );
      expect(blurred.length, crisp.length);
      var differ = false;
      for (var i = 0; i < blurred.length && !differ; i++) {
        differ = blurred[i] != crisp[i];
      }
      expect(
        differ,
        isTrue,
        reason:
            'a mid-ramp panning frame with scene blur must differ '
            'from the crisp compose; identical bytes mean the smear '
            'never reached the output',
      );
    });

    test(
      '3D tilt motion contributes projective blur at the product maximum',
      () async {
        Future<Uint8List> composeTilt({required double motionBlur}) async {
          final compositor = FrameCompositor(
            projectState: EditorProjectState.defaults().copyWith(
              motionBlur: motionBlur,
              screenMovementBlur: 1,
              screenZoomBlur: 1,
              zoomRegions: [
                ZoomRegion(
                  rect: const Rect.fromLTWH(190, 120, 60, 60),
                  startTime: Duration.zero,
                  duration: const Duration(milliseconds: 900),
                  zoomLevel: 2,
                  followCursor: false,
                  enterDuration: const Duration(milliseconds: 400),
                  exitDuration: const Duration(milliseconds: 300),
                  tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
                ),
              ],
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
          try {
            final signal = compositor.sceneMotionSignalAt(
              const Duration(milliseconds: 220),
            );
            if (motionBlur > 0) {
              expect(signal.projectiveTransform, isNotNull);
              expect(signal.projectiveTransform!.isIdentity, isFalse);
            }
            return await compositor.compose(
              videoFrameBgra: _twoTone(320, 240),
              position: const Duration(milliseconds: 220),
            );
          } finally {
            compositor.dispose();
          }
        }

        final blurred = await composeTilt(motionBlur: 0.5);
        final crisp = await composeTilt(motionBlur: 0);
        expect(blurred, isNot(equals(crisp)));
      },
    );

    test('_loadWallpaperPhoto disposes the codec even when decoding '
        'throws', () async {
      // The whole point of the try/finally: a throw from getNextFrame
      // must still dispose the codec instead of leaking it.
      final compositor = _wallpaperCompositor();
      final spy = _SpyCodec.throwing();
      compositor.wallpaperCodecFactoryOverride =
          (assetPath, targetWidth) async => spy;

      await expectLater(
        compositor.debugLoadWallpaperPhoto('macOS', 0),
        throwsA(isA<StateError>()),
      );
      expect(
        spy.disposed,
        isTrue,
        reason: 'codec must be disposed via finally even when decode throws',
      );
    });
  });
}

/// Compositor with a "None" frame, used to exercise [debugLoadWallpaperPhoto]
/// directly (the passed category drives the load, not the frame's wallpaper).
FrameCompositor _wallpaperCompositor({Size? outputSize}) => FrameCompositor(
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
  outputSize: outputSize,
  fps: 30,
);

Future<ui.Image> _make1x1Image() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(const [0, 0, 0, 0xFF]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Fake [ui.Codec] that records dispose/decode calls so the wallpaper
/// loader's resource-cleanup contract can be asserted.
class _SpyCodec implements ui.Codec {
  _SpyCodec(ui.Image image) : _image = image, _throwOnDecode = false;
  _SpyCodec.throwing() : _image = null, _throwOnDecode = true;

  final ui.Image? _image;
  final bool _throwOnDecode;
  bool disposed = false;
  int getNextFrameCalls = 0;

  @override
  int get frameCount => 1;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    getNextFrameCalls++;
    if (_throwOnDecode) throw StateError('decode failed');
    return _SpyFrameInfo(_image!);
  }

  @override
  void dispose() => disposed = true;
}

class _SpyFrameInfo implements ui.FrameInfo {
  _SpyFrameInfo(this.image);

  @override
  final ui.Image image;

  @override
  Duration get duration => Duration.zero;
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
