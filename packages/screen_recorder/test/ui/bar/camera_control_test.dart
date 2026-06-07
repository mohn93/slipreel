// packages/screen_recorder/test/ui/bar/camera_control_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  testWidgets('camera control shows label and fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CameraControlForTest(
          camera: const CameraConfig(deviceUid: 'u', deviceLabel: 'FaceTime HD'),
          onTap: () => taps++,
        ),
      ),
    ));
    expect(find.text('FaceTime HD'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bar-camera')));
    expect(taps, 1);
  });

  testWidgets('camera control shows "No camera" when off', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CameraControlForTest(camera: null, onTap: () {}),
      ),
    ));
    expect(find.text('No camera'), findsOneWidget);
  });
}
