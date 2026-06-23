import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:screen_recorder/state/device_frame_catalog_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/device_tab.dart';

void main() {
  testWidgets('shows "Use device mockup" and a color chip enables the frame',
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
              screenRect: DeviceScreenRect(l: .05, t: .02, r: .95, b: .98),
            ),
            landscape: DeviceFrameOrientationAsset(
              asset: 'b',
              bezelWidth: 2760,
              bezelHeight: 1350,
              screenRect: DeviceScreenRect(l: .02, t: .05, r: .98, b: .95),
            ),
          ),
        ],
      ),
    ]));
    addTearDown(() => debugSetDeviceFrameCatalog(null));

    final controller = EditorProjectController(
      initial:
          EditorProjectState.defaults().copyWith(windowFrame: WindowFrame.none()),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => controller),
        deviceFrameCatalogProvider
            .overrideWith((ref) async => loadDeviceFrameCatalog()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: DeviceTab(recordingSize: Size(1206, 2622)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Use device mockup'), findsOneWidget);
    expect(controller.current.windowFrame.deviceFrameId, isNull);

    await tester.tap(find.text('Black').first);
    await tester.pump();
    expect(controller.current.windowFrame.deviceFrameId, 'iphone-16-pro');
    expect(controller.current.windowFrame.deviceFrameColor, 'black');
  });

  testWidgets(
      'Perfect/Flexible filter survives the tab being rebuilt (provider-backed)',
      (tester) async {
    // The inspector builds DeviceTab via a `switch` on the selected tab, so it
    // is disposed + recreated on every tab switch. The filter therefore can't
    // live in widget State (it would reset to Perfect on every revisit) — it
    // must be provider-backed and survive the rebuild.
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
              screenRect: DeviceScreenRect(l: .05, t: .02, r: .95, b: .98),
            ),
            landscape: DeviceFrameOrientationAsset(
              asset: 'b',
              bezelWidth: 2760,
              bezelHeight: 1350,
              screenRect: DeviceScreenRect(l: .02, t: .05, r: .98, b: .95),
            ),
          ),
        ],
      ),
    ]));
    addTearDown(() => debugSetDeviceFrameCatalog(null));

    // A shared container that outlives the widgets, so the session-scoped
    // provider survives DeviceTab being disposed and recreated.
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith((ref) =>
          EditorProjectController(
              initial: EditorProjectState.defaults()
                  .copyWith(windowFrame: WindowFrame.none()))),
      deviceFrameCatalogProvider
          .overrideWith((ref) async => loadDeviceFrameCatalog()),
    ]);
    addTearDown(container.dispose);

    Widget host(Widget child) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: Scaffold(body: child)),
        );
    InspectorChipGroup<bool> chipGroup() =>
        tester.widget<InspectorChipGroup<bool>>(
            find.byType(InspectorChipGroup<bool>));

    await tester
        .pumpWidget(host(const DeviceTab(recordingSize: Size(1206, 2622))));
    await tester.pumpAndSettle();
    expect(chipGroup().selected, isFalse, reason: 'defaults to Perfect');

    // Switch to Flexible.
    await tester.tap(find.text('Flexible'));
    await tester.pump();
    expect(container.read(deviceFramePickerFlexibleProvider), isTrue);
    expect(chipGroup().selected, isTrue);

    // Leave the tab (dispose DeviceTab) ...
    await tester.pumpWidget(host(const SizedBox.shrink()));
    await tester.pump();

    // ... and come back: a fresh DeviceTab must still show Flexible, not reset.
    await tester
        .pumpWidget(host(const DeviceTab(recordingSize: Size(1206, 2622))));
    await tester.pumpAndSettle();
    expect(chipGroup().selected, isTrue,
        reason: 'filter must persist across tab rebuild');
  });
}
