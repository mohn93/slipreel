import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/state/frame_extractor_provider.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';

/// End-to-end wiring: with a video path set, the zoom context inspector watches
/// [frameExtractorProvider] and feeds the resulting frame to the placement box.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manual zoom placement box shows the extracted frame',
      (tester) async {
    // Build the ui.Image via runAsync — decodeImageFromPixels relies on an
    // engine callback that never fires under testWidgets' fake-async zone.
    final img = await tester.runAsync(
        () => decodeRgbaToImage(Uint8List(4 * 4 * 4), 4, 4));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Ignore the key — any frame request resolves to our test image.
          frameExtractorProvider.overrideWith((ref, key) async => img),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: const [AppPalette.midnight],
            useMaterial3: true,
          ),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 700,
              child: ZoomContextInspector(
                zoom: ZoomRegion(
                  rect: const Rect.fromLTWH(0, 0, 400, 300),
                  startTime: Duration.zero,
                  duration: const Duration(seconds: 2),
                  zoomLevel: 2.0,
                  followCursor: false, // manual placement → placement box shown
                ),
                zoomNumber: 1,
                onChanged: (_) {},
                onDelete: () {},
                onClose: () {},
                curveLibrary: FileCurveLibrary(),
                onCurveOverrideChanged: (_) {},
                videoSize: const Size(400, 300),
                videoPath: '/fake.mp4',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('zoom-placement-frame')), findsOneWidget);
  });
}
