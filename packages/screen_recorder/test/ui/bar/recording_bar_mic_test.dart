import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:screen_recorder/ui/bar/mic_level_meter.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<TipsController> _allSeenController() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  for (final id in TipId.values) {
    await c.markSeen(id);
  }
  return c;
}

Widget _wrap(Widget c, TipsController tips) => ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => tips)],
      child: MaterialApp(home: Scaffold(body: c)),
    );

RecordingBar _bar(
        {MicrophoneConfig? mic,
        VoidCallback? onMicTap,
        Stream<double>? level}) =>
    RecordingBar(
      onPickMode: (_) {},
      onClose: () {},
      onGearTap: () {},
      onDragStart: () {},
      microphone: mic,
      onMicTap: onMicTap ?? () {},
      onSystemAudioTap: () {},
      onCameraTap: () {},
      micLevelStream: level,
    );

void main() {
  testWidgets('off state shows "No microphone"', (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(mic: null), tips));
    expect(find.text('No microphone'), findsOneWidget);
  });

  testWidgets('on state shows the device label', (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(
        _bar(
            mic: const MicrophoneConfig(
                deviceUid: 'u', deviceLabel: 'MacBook Pro Mic')),
        tips));
    expect(find.text('MacBook Pro Mic'), findsOneWidget);
    expect(find.text('No microphone'), findsNothing);
  });

  testWidgets('a very long device label does not overflow', (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(
        _bar(
            mic: const MicrophoneConfig(
                deviceUid: 'u',
                deviceLabel:
                    'Extremely Long Virtual Audio Capture Device Name That Would Overflow')),
        tips));
    await tester.pump();
    expect(tester.takeException(), isNull); // no RenderFlex overflow
  });

  testWidgets('tapping the mic control fires onMicTap', (tester) async {
    _wide(tester);
    var tapped = false;
    final tips = await _allSeenController();
    await tester
        .pumpWidget(_wrap(_bar(onMicTap: () => tapped = true), tips));
    await tester.tap(find.byKey(const Key('bar-mic')));
    expect(tapped, isTrue);
  });

  testWidgets('shows the meter under the mic when a stream is provided',
      (tester) async {
    _wide(tester);
    final c = StreamController<double>.broadcast();
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(
      _bar(
        mic: const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic'),
        level: c.stream,
      ),
      tips,
    ));
    expect(find.byType(MicLevelMeter), findsOneWidget);
    await c.close();
  });

  testWidgets('no meter when no level stream (off)', (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(mic: null), tips));
    expect(find.byType(MicLevelMeter), findsNothing);
  });
}
