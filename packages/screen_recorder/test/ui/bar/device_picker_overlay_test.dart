import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/device_picker_overlay.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  testWidgets('empty state shows the connect/trust hint', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => DevicePickerOverlay.show(context, devices: const []),
          child: const Text('open'),
        );
      })),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connect an iPhone or iPad'), findsOneWidget);
  });

  testWidgets('tapping a device returns it', (tester) async {
    DeviceSource? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () async {
            picked = await DevicePickerOverlay.show(context, devices: const [
              DeviceSource(id: 'uid-1', name: 'My iPhone', kind: DeviceKind.phone),
            ]);
          },
          child: const Text('open'),
        );
      })),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My iPhone'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'uid-1');
  });
}
