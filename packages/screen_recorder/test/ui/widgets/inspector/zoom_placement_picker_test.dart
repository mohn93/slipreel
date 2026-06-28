import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:screen_recorder/state/frame_extractor_provider.dart'
    show decodeRgbaToImage;
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';

/// Builds a tiny 4×4 RGBA image (used as a fake screen frame / bezel source).
Future<ui.Image> _image() => decodeRgbaToImage(Uint8List(4 * 4 * 4), 4, 4);

/// A valid 1×1 transparent PNG — a real encoded image so `MemoryImage` can
/// decode it (the bezel goes through the async image-decode path).
final Uint8List _png1x1 = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, //
  0x00, 0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F, //
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
  0xAE, 0x42, 0x60, 0x82,
]);

Future<void> _pump(WidgetTester tester, Widget child, {double width = 300}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: child)),
      ),
    ),
  );
}

/// The magnify-in-place viewport box (canvas coords) computed the same way
/// the widget (and the render) does — used as the test oracle.
Rect _expectedBox({
  required Size videoSize,
  required Size canvasSize,
  required Rect videoRect,
  required Rect focal,
  required double z,
}) {
  final sx = videoRect.width / videoSize.width;
  final sy = videoRect.height / videoSize.height;
  final canvasFocal = videoRect.topLeft +
      Offset(focal.center.dx * sx, focal.center.dy * sy);
  final canvasCenter = Offset(canvasSize.width / 2, canvasSize.height / 2);
  final vc = canvasCenter + (canvasFocal - canvasCenter) * (1 - 1 / z);
  return Rect.fromCenter(
    center: vc,
    width: canvasSize.width / z,
    height: canvasSize.height / z,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('viewport box geometry (normal, padded)', () {
    // A normal recording with padding: 1920×1080 video centered inside a
    // 2200×1300 canvas.
    const videoSize = Size(1920, 1080);
    const canvasSize = Size(2200, 1300);
    final videoRect = Rect.fromLTWH(
      (canvasSize.width - videoSize.width) / 2, // 140
      (canvasSize.height - videoSize.height) / 2, // 110
      videoSize.width,
      videoSize.height,
    );

    testWidgets('box rect (canvas, pre-scale) equals magnify-in-place oracle',
        (tester) async {
      const z = 2.0;
      final focal = Rect.fromCenter(
        center: const Offset(1400, 800),
        width: videoSize.width / z,
        height: videoSize.height / z,
      );
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          zoomLevel: z,
          rect: focal,
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );

      final mini = tester.getRect(
          find.byKey(const Key('zoom-placement-mini-frame')));
      final miniScale = mini.width / canvasSize.width;
      final boxMini =
          tester.getRect(find.byKey(const Key('zoom-placement-inner-rect')));

      final expected = _expectedBox(
        videoSize: videoSize,
        canvasSize: canvasSize,
        videoRect: videoRect,
        focal: focal,
        z: z,
      );
      // Convert the rendered (screen) box back to canvas coords: subtract the
      // mini-frame origin, divide by miniScale.
      final actualCanvas = Rect.fromLTWH(
        (boxMini.left - mini.left) / miniScale,
        (boxMini.top - mini.top) / miniScale,
        boxMini.width / miniScale,
        boxMini.height / miniScale,
      );
      expect(actualCanvas.left, closeTo(expected.left, 0.5));
      expect(actualCanvas.top, closeTo(expected.top, 0.5));
      expect(actualCanvas.width, closeTo(expected.width, 0.5));
      expect(actualCanvas.height, closeTo(expected.height, 0.5));
    });

    testWidgets('drag maps screen delta → focal correctly', (tester) async {
      const z = 2.0;
      Rect? committed;
      final focal = Rect.fromCenter(
        center: const Offset(960, 540), // canvas-center focal
        width: videoSize.width / z,
        height: videoSize.height / z,
      );
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          zoomLevel: z,
          rect: focal,
          onPreview: (_) {},
          onCommit: (r) => committed = r,
        ),
      );

      final mini = tester.getRect(
          find.byKey(const Key('zoom-placement-mini-frame')));
      final miniScale = mini.width / canvasSize.width;
      // A small screen-space drag that won't hit the clamp.
      const screenDelta = Offset(20, 12);

      final box = find.byKey(const Key('zoom-placement-inner-rect'));
      await tester.timedDrag(box, screenDelta, const Duration(milliseconds: 80));
      await tester.pumpAndSettle();

      expect(committed, isNotNull);

      // Invert: vc0 (canvas-center focal → canvasCenter), vc' = vc0 +
      // delta/miniScale, focal' = fromCanvas(canvasCenter + (vc'-cc)/(1-1/z)).
      final canvasCenter =
          Offset(canvasSize.width / 2, canvasSize.height / 2);
      final vc0 = canvasCenter; // because focal == canvas center
      final vcPrime = vc0 + screenDelta / miniScale;
      final canvasFocal =
          canvasCenter + (vcPrime - canvasCenter) / (1 - 1 / z);
      final sx = videoRect.width / videoSize.width;
      final sy = videoRect.height / videoSize.height;
      final expectedCenter = Offset(
        (canvasFocal.dx - videoRect.left) / sx,
        (canvasFocal.dy - videoRect.top) / sy,
      );

      expect(committed!.center.dx, closeTo(expectedCenter.dx, 1.5));
      expect(committed!.center.dy, closeTo(expectedCenter.dy, 1.5));
      expect(committed!.size.width, closeTo(videoSize.width / z, 0.5));
      expect(committed!.size.height, closeTo(videoSize.height / z, 0.5));
    });

    testWidgets('drag past edge clamps the box to the canvas', (tester) async {
      const z = 2.0;
      Rect? committed;
      final focal = Rect.fromCenter(
        center: const Offset(960, 540),
        width: videoSize.width / z,
        height: videoSize.height / z,
      );
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          zoomLevel: z,
          rect: focal,
          onPreview: (_) {},
          onCommit: (r) => committed = r,
        ),
      );

      final box = find.byKey(const Key('zoom-placement-inner-rect'));
      // Drag far past the top-left corner.
      await tester.timedDrag(
          box, const Offset(-2000, -2000), const Duration(milliseconds: 80));
      await tester.pumpAndSettle();

      expect(committed, isNotNull);

      // The box, recomputed from the committed focal, must sit at the canvas
      // top-left corner (vc clamped to half-box).
      final sx = videoRect.width / videoSize.width;
      final sy = videoRect.height / videoSize.height;
      final canvasFocal = videoRect.topLeft +
          Offset(committed!.center.dx * sx, committed!.center.dy * sy);
      final canvasCenter =
          Offset(canvasSize.width / 2, canvasSize.height / 2);
      final vc = canvasCenter + (canvasFocal - canvasCenter) * (1 - 1 / z);
      final boxLeft = vc.dx - canvasSize.width / (2 * z);
      final boxTop = vc.dy - canvasSize.height / (2 * z);
      expect(boxLeft, closeTo(0, 0.5));
      expect(boxTop, closeTo(0, 0.5));
    });
  });

  group('viewport box geometry (device)', () {
    // A device layout where the video sits inside a bezel within the canvas.
    const videoSize = Size(1170, 2532);
    const canvasSize = Size(1400, 2800);
    final videoRect = const Rect.fromLTWH(160, 120, 1080, 2336);
    final layout = DeviceFrameLayout(
      canvasSize: canvasSize,
      bezelRect: const Rect.fromLTWH(140, 100, 1120, 2600),
      screenRect: videoRect,
      videoRect: videoRect,
      videoCornerRadius: 48,
    );

    testWidgets('box equals magnify-in-place oracle for device geometry',
        (tester) async {
      const z = 2.5;
      final bezel = MemoryImage(_png1x1);
      final focal = Rect.fromCenter(
        center: const Offset(300, 600),
        width: videoSize.width / z,
        height: videoSize.height / z,
      );
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'Abstract',
          wallpaperIndex: 2,
          deviceLayout: layout,
          bezel: bezel,
          zoomLevel: z,
          rect: focal,
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );

      final mini = tester.getRect(
          find.byKey(const Key('zoom-placement-mini-frame')));
      final miniScale = mini.width / canvasSize.width;
      final boxMini =
          tester.getRect(find.byKey(const Key('zoom-placement-inner-rect')));

      final expected = _expectedBox(
        videoSize: videoSize,
        canvasSize: canvasSize,
        videoRect: videoRect,
        focal: focal,
        z: z,
      );
      final actualCanvas = Rect.fromLTWH(
        (boxMini.left - mini.left) / miniScale,
        (boxMini.top - mini.top) / miniScale,
        boxMini.width / miniScale,
        boxMini.height / miniScale,
      );
      expect(actualCanvas.left, closeTo(expected.left, 0.6));
      expect(actualCanvas.top, closeTo(expected.top, 0.6));
      expect(actualCanvas.width, closeTo(expected.width, 0.6));
      expect(actualCanvas.height, closeTo(expected.height, 0.6));
    });
  });

  group('z == 1', () {
    const videoSize = Size(1920, 1080);
    const canvasSize = Size(2200, 1300);
    final videoRect = const Rect.fromLTWH(140, 110, 1920, 1080);

    testWidgets('box fills the canvas and drag is disabled', (tester) async {
      Rect? committed;
      Rect? previewed;
      final focal = Rect.fromCenter(
        center: const Offset(960, 540),
        width: videoSize.width,
        height: videoSize.height,
      );
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          zoomLevel: 1.0,
          rect: focal,
          onPreview: (r) => previewed = r,
          onCommit: (r) => committed = r,
        ),
      );

      final mini = tester.getRect(
          find.byKey(const Key('zoom-placement-mini-frame')));
      final box =
          tester.getRect(find.byKey(const Key('zoom-placement-inner-rect')));
      // Box fills the whole mini-frame.
      expect(box.width, closeTo(mini.width, 0.5));
      expect(box.height, closeTo(mini.height, 0.5));

      // Drag attempts emit nothing.
      await tester.timedDrag(
          find.byKey(const Key('zoom-placement-inner-rect')),
          const Offset(40, 40),
          const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      expect(previewed, isNull);
      expect(committed, isNull);
    });
  });

  group('builds for all input shapes', () {
    const videoSize = Size(1920, 1080);
    const canvasSize = Size(2200, 1300);
    final videoRect = const Rect.fromLTWH(140, 110, 1920, 1080);
    final focal = Rect.fromCenter(
        center: const Offset(960, 540), width: 960, height: 540);

    testWidgets('normal, no screen frame', (tester) async {
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          zoomLevel: 2.0,
          rect: focal,
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('zoom-placement-mini-frame')),
          findsOneWidget);
      expect(find.byKey(const Key('zoom-placement-spotlight')), findsOneWidget);
      expect(find.byKey(const Key('zoom-placement-screen-placeholder')),
          findsOneWidget);
    });

    testWidgets('normal, with screen frame', (tester) async {
      final frame = await tester.runAsync(_image);
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'Solid',
          wallpaperIndex: 0,
          wallpaperSolidColor: const Color(0xFF223344),
          screenFrame: frame,
          zoomLevel: 2.0,
          rect: focal,
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('zoom-placement-screen')), findsOneWidget);
    });

    testWidgets('device, with and without screen frame', (tester) async {
      final layout = DeviceFrameLayout(
        canvasSize: const Size(1400, 2800),
        bezelRect: const Rect.fromLTWH(140, 100, 1120, 2600),
        screenRect: const Rect.fromLTWH(160, 120, 1080, 2336),
        videoRect: const Rect.fromLTWH(160, 120, 1080, 2336),
        videoCornerRadius: 48,
      );
      final bezel = MemoryImage(_png1x1);

      // Without frame.
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: const Size(1170, 2532),
          canvasSize: const Size(1400, 2800),
          videoRect: const Rect.fromLTWH(160, 120, 1080, 2336),
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          deviceLayout: layout,
          bezel: bezel,
          zoomLevel: 2.0,
          rect: Rect.fromCenter(
              center: const Offset(585, 1266), width: 585, height: 1266),
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('zoom-placement-device')), findsOneWidget);

      // With frame.
      final frame = await tester.runAsync(_image);
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: const Size(1170, 2532),
          canvasSize: const Size(1400, 2800),
          videoRect: const Rect.fromLTWH(160, 120, 1080, 2336),
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          deviceLayout: layout,
          bezel: bezel,
          screenFrame: frame,
          zoomLevel: 2.0,
          rect: Rect.fromCenter(
              center: const Offset(585, 1266), width: 585, height: 1266),
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('zoom-placement-device')), findsOneWidget);
    });
  });

  group('no wallpaper (category == null)', () {
    const videoSize = Size(1920, 1080);
    const canvasSize = Size(2200, 1300);
    final videoRect = const Rect.fromLTWH(140, 110, 1920, 1080);
    final focal = Rect.fromCenter(
        center: const Offset(960, 540), width: 960, height: 540);

    testWidgets('does NOT render a wallpaper layer; matches the render which '
        'draws none', (tester) async {
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: null,
          wallpaperIndex: 0,
          zoomLevel: 2.0,
          rect: focal,
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
      // The wallpaper layer is absent (the neutral mini-frame fill shows
      // through), exactly like the render's null-wallpaper path.
      expect(find.byKey(const Key('zoom-placement-wallpaper')), findsNothing);
      // The mini-frame, box and spotlight still render.
      expect(find.byKey(const Key('zoom-placement-mini-frame')),
          findsOneWidget);
      expect(find.byKey(const Key('zoom-placement-inner-rect')), findsOneWidget);
    });

    testWidgets('a non-null category DOES render a wallpaper layer',
        (tester) async {
      await _pump(
        tester,
        ZoomPlacementPicker(
          videoSize: videoSize,
          canvasSize: canvasSize,
          videoRect: videoRect,
          wallpaperCategory: 'macOS',
          wallpaperIndex: 0,
          zoomLevel: 2.0,
          rect: focal,
          onPreview: (_) {},
          onCommit: (_) {},
        ),
      );
      expect(find.byKey(const Key('zoom-placement-wallpaper')), findsOneWidget);
    });
  });

  testWidgets('mini-frame aspect matches canvasSize', (tester) async {
    const canvasSize = Size(2200, 1300);
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: const Size(1920, 1080),
        canvasSize: canvasSize,
        videoRect: const Rect.fromLTWH(140, 110, 1920, 1080),
        wallpaperCategory: 'macOS',
        wallpaperIndex: 0,
        zoomLevel: 2.0,
        rect: Rect.fromCenter(
            center: const Offset(960, 540), width: 960, height: 540),
        onPreview: (_) {},
        onCommit: (_) {},
      ),
    );
    final mini =
        tester.getRect(find.byKey(const Key('zoom-placement-mini-frame')));
    expect(mini.width, closeTo(280, 0.5));
    expect(mini.height / mini.width,
        closeTo(canvasSize.height / canvasSize.width, 0.001));
  });
}
