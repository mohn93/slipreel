import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _wrap(Widget c) => MaterialApp(home: Scaffold(body: c));

RecordingBar _bar({MicrophoneConfig? mic, VoidCallback? onMicTap}) => RecordingBar(
      onPickMode: (_) {},
      onClose: () {},
      onGearTap: () {},
      onDragStart: () {},
      microphone: mic,
      onMicTap: onMicTap ?? () {},
    );

void main() {
  testWidgets('off state shows "No microphone"', (tester) async {
    _wide(tester);
    await tester.pumpWidget(_wrap(_bar(mic: null)));
    expect(find.text('No microphone'), findsOneWidget);
  });

  testWidgets('on state shows the device label', (tester) async {
    _wide(tester);
    await tester.pumpWidget(_wrap(_bar(
        mic: const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'MacBook Pro Mic'))));
    expect(find.text('MacBook Pro Mic'), findsOneWidget);
    expect(find.text('No microphone'), findsNothing);
  });

  testWidgets('a very long device label does not overflow', (tester) async {
    _wide(tester);
    await tester.pumpWidget(_wrap(_bar(
        mic: const MicrophoneConfig(
            deviceUid: 'u',
            deviceLabel:
                'Extremely Long Virtual Audio Capture Device Name That Would Overflow'))));
    await tester.pump();
    expect(tester.takeException(), isNull); // no RenderFlex overflow
  });

  testWidgets('tapping the mic control fires onMicTap', (tester) async {
    _wide(tester);
    var tapped = false;
    await tester.pumpWidget(_wrap(_bar(onMicTap: () => tapped = true)));
    await tester.tap(find.byKey(const Key('bar-mic')));
    expect(tapped, isTrue);
  });
}
