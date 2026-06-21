import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/frame_extractor_provider.dart'
    show decodeRgbaToImage;
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';

Future<ui.Image> _image() => decodeRgbaToImage(Uint8List(4 * 4 * 4), 4, 4);

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 280, child: child)),
      ),
    );

ZoomPlacementPicker _picker({ui.Image? bg}) => ZoomPlacementPicker(
      videoSize: const Size(400, 300),
      rect: const Rect.fromLTWH(50, 50, 200, 150),
      zoomLevel: 2.0,
      onPreview: (_) {},
      onCommit: (_) {},
      backgroundImage: bg,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('paints frame + spotlight when a background image is provided',
      (tester) async {
    // Build the ui.Image via runAsync — decodeImageFromPixels relies on an
    // engine callback that never fires under testWidgets' fake-async zone.
    final bg = await tester.runAsync(_image);
    await tester.pumpWidget(_host(_picker(bg: bg)));

    expect(find.byKey(const Key('zoom-placement-frame')), findsOneWidget);
    expect(find.byKey(const Key('zoom-placement-spotlight')), findsOneWidget);
  });

  testWidgets('no frame/spotlight layers without a background image',
      (tester) async {
    await tester.pumpWidget(_host(_picker(bg: null)));

    expect(find.byKey(const Key('zoom-placement-frame')), findsNothing);
    expect(find.byKey(const Key('zoom-placement-spotlight')), findsNothing);
  });
}
