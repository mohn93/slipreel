// packages/screen_recorder/test/ui/background_tab_device_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:screen_recorder/state/device_frame_catalog_provider.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/background_tab.dart';

void main() {
  testWidgets('device section shows "Use device mockup" and toggles it on',
      (tester) async {
    debugSetDeviceFrameCatalog(const DeviceFrameCatalog([
      DeviceFrameEntry(
        id: 'iphone-16-pro',
        family: 'iPhone 16 Pro',
        kind: 'phone',
        screenWidth: 1206,
        screenHeight: 2622,
        colors: [
          DeviceFrameColorVariant(
            id: 'black',
            name: 'Black',
            swatch: Color(0xFF000000),
            portrait: DeviceFrameOrientationAsset(
              asset: 'a',
              bezelWidth: 1350,
              bezelHeight: 2760,
              screenRect: DeviceScreenRect(l: .05, t: .02, r: .95, b: .98)),
            landscape: DeviceFrameOrientationAsset(
              asset: 'b',
              bezelWidth: 2760,
              bezelHeight: 1350,
              screenRect: DeviceScreenRect(l: .02, t: .05, r: .98, b: .95))),
        ]),
    ]));
    addTearDown(() => debugSetDeviceFrameCatalog(null));

    final controller = EditorProjectController(
      initial: EditorProjectState.defaults()
          .copyWith(windowFrame: WindowFrame.none()),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => controller),
        deviceFrameCatalogProvider.overrideWith(
            (ref) async => (await loadDeviceFrameCatalog())),
      ],
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: const Scaffold(
          body: BackgroundTab(isDevice: true, recordingSize: Size(1206, 2622)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Use device mockup'), findsOneWidget);
    // Toggle it on via the matched device's color chip.
    await tester.tap(find.text('Black').first);
    await tester.pump();
    expect(controller.current.windowFrame.deviceFrameId, 'iphone-16-pro');
  });

  testWidgets('no device section for non-device recordings', (tester) async {
    final controller = EditorProjectController(
      initial: EditorProjectState.defaults());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => controller),
      ],
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: const Scaffold(body: BackgroundTab(isDevice: false)),
      ),
    ));
    await tester.pump();
    expect(find.text('Use device mockup'), findsNothing);
  });
}
