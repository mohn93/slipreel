import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A TipsController with all tips pre-seen so TipAnchor overlays don't
/// appear during bar tests (which test bar behaviour, not tips).
Future<TipsController> _allSeenController() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  for (final id in TipId.values) {
    await c.markSeen(id);
  }
  return c;
}

Widget _wrap(Widget child, TipsController tips) => ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => tips)],
      child: MaterialApp(home: Scaffold(body: child)),
    );

RecordingBar _bar({
  void Function(BarSourceMode)? onPickMode,
  MicrophoneConfig? microphone,
  bool deviceMode = false,
  bool deviceAudioEnabled = true,
  VoidCallback? onDeviceAudioTap,
}) =>
    RecordingBar(
      onPickMode: onPickMode ?? (_) {},
      onClose: () {},
      onGearTap: () {},
      onDragStart: () {},
      microphone: microphone,
      onMicTap: () {},
      onSystemAudioTap: () {},
      onCameraTap: () {},
      deviceMode: deviceMode,
      deviceAudioEnabled: deviceAudioEnabled,
      onDeviceAudioTap: onDeviceAudioTap,
    );

void main() {
  testWidgets(
      'deviceMode:false renders system-audio control and no device-audio control',
      (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(deviceMode: false), tips));

    expect(find.byKey(const Key('bar-system-audio')), findsOneWidget);
    expect(find.byKey(const Key('bar-device-audio')), findsNothing);
  });

  testWidgets(
      'deviceMode:true renders device-audio control in place of system-audio, '
      'keeping the mic control', (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(deviceMode: true), tips));

    expect(find.byKey(const Key('bar-system-audio')), findsNothing);
    expect(find.byKey(const Key('bar-device-audio')), findsOneWidget);
    // Mic control stays present in device mode.
    expect(find.byKey(const Key('bar-mic')), findsOneWidget);
  });

  testWidgets('tapping the device-audio control fires onDeviceAudioTap',
      (tester) async {
    _wide(tester);
    var tapped = false;
    final tips = await _allSeenController();
    await tester.pumpWidget(
      _wrap(_bar(deviceMode: true, onDeviceAudioTap: () => tapped = true), tips),
    );
    await tester.tap(find.byKey(const Key('bar-device-audio')));
    expect(tapped, isTrue);
  });

  testWidgets('tapping the Device chip fires onPickMode(device)',
      (tester) async {
    _wide(tester);
    BarSourceMode? picked;
    final tips = await _allSeenController();
    await tester
        .pumpWidget(_wrap(_bar(onPickMode: (m) => picked = m), tips));
    await tester.tap(find.text('Device'));
    expect(picked, BarSourceMode.device);
  });
}
