import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/state/frame_extractor_provider.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';

/// Wiring guard: `ZoomContextInspector` forwards the COMPOSED-canvas geometry
/// (canvasSize / videoRect / wallpaper / device layout + bezel) it receives
/// from the host to `ZoomPlacementPicker` — NOT the bare-video canvas — so the
/// placement box matches what the live canvas renders.
/// A valid 1×1 transparent PNG so `MemoryImage` decodes a real bezel without
/// hitting the asset bundle (which has no test assets registered).
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpInspector(
    WidgetTester tester, {
    required ZoomPlacementGeometry? geometry,
    Size videoSize = const Size(1920, 1080),
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          // No real frame extraction in this test.
          frameExtractorProvider.overrideWith((ref, key) async => null),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: const [AppPalette.midnight],
            useMaterial3: true,
          ),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 800,
              child: ZoomContextInspector(
                zoom: ZoomRegion(
                  rect: Rect.fromLTWH(0, 0, videoSize.width, videoSize.height),
                  startTime: Duration.zero,
                  duration: const Duration(seconds: 2),
                  zoomLevel: 2.0,
                  followCursor: false, // manual → placement section shown
                ),
                zoomNumber: 1,
                onChanged: (_) {},
                onDelete: () {},
                onClose: () {},
                curveLibrary: FileCurveLibrary(),
                onCurveOverrideChanged: (_) {},
                videoSize: videoSize,
                placementGeometry: geometry,
                videoPath: '', // no frame extraction
              ),
            ),
          ),
        ),
      ),
    );
  }

  ZoomPlacementPicker readPicker(WidgetTester tester) =>
      tester.widget<ZoomPlacementPicker>(find.byType(ZoomPlacementPicker));

  testWidgets('forwards composed padded geometry (canvas != video)',
      (tester) async {
    const videoSize = Size(1920, 1080);
    const canvasSize = Size(2200, 1300);
    final videoRect = Rect.fromLTWH(
      (canvasSize.width - videoSize.width) / 2,
      (canvasSize.height - videoSize.height) / 2,
      videoSize.width,
      videoSize.height,
    );

    await pumpInspector(
      tester,
      geometry: ZoomPlacementGeometry(
        canvasSize: canvasSize,
        videoRect: videoRect,
        wallpaperCategory: 'Sunset',
        wallpaperIndex: 3,
        wallpaperSolidColor: const Color(0xFF112233),
      ),
    );
    await tester.pump();

    final picker = readPicker(tester);
    // The composed canvas is bigger than the bare video → padding present.
    expect(picker.canvasSize, canvasSize);
    expect(picker.videoRect, videoRect);
    expect(picker.videoSize, videoSize);
    // Wallpaper threaded through, not the macOS/0 fallback.
    expect(picker.wallpaperCategory, 'Sunset');
    expect(picker.wallpaperIndex, 3);
    expect(picker.wallpaperSolidColor, const Color(0xFF112233));
    // No device frame → null layout/bezel.
    expect(picker.deviceLayout, isNull);
    expect(picker.bezel, isNull);
  });

  testWidgets('forwards device layout + bezel when a device frame is active',
      (tester) async {
    const videoSize = Size(1170, 2532); // portrait phone recording
    const canvasSize = Size(1400, 2900);
    final layout = DeviceFrameLayout(
      canvasSize: canvasSize,
      bezelRect: const Rect.fromLTWH(100, 150, 1200, 2600),
      screenRect: const Rect.fromLTWH(130, 190, 1140, 2520),
      videoRect: const Rect.fromLTWH(140, 200, 1120, 2500),
      videoCornerRadius: 60,
    );

    await pumpInspector(
      tester,
      videoSize: videoSize,
      geometry: ZoomPlacementGeometry(
        canvasSize: canvasSize,
        videoRect: layout.videoRect,
        wallpaperCategory: 'macOS',
        wallpaperIndex: 0,
        deviceLayout: layout,
        bezel: MemoryImage(_png1x1),
      ),
    );
    await tester.pump();

    final picker = readPicker(tester);
    expect(picker.canvasSize, canvasSize);
    expect(picker.videoRect, layout.videoRect);
    expect(picker.deviceLayout, same(layout));
    expect(picker.bezel, isA<MemoryImage>());
  });

  testWidgets('null geometry degrades to the bare-video canvas',
      (tester) async {
    const videoSize = Size(1920, 1080);
    await pumpInspector(tester, geometry: null, videoSize: videoSize);
    await tester.pump();

    final picker = readPicker(tester);
    // Fallback: canvas == video, video fills the canvas, no device frame.
    expect(picker.canvasSize, videoSize);
    expect(picker.videoRect, Offset.zero & videoSize);
    expect(picker.deviceLayout, isNull);
    expect(picker.bezel, isNull);
  });
}
