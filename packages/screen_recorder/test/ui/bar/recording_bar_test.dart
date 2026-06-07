import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 600);
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
  VoidCallback? onClose,
  VoidCallback? onGearTap,
  VoidCallback? onDragStart,
  MicrophoneConfig? microphone,
  VoidCallback? onMicTap,
  VoidCallback? onSystemAudioTap,
  VoidCallback? onCameraTap,
}) =>
    RecordingBar(
      onPickMode: onPickMode ?? (_) {},
      onClose: onClose ?? () {},
      onGearTap: onGearTap ?? () {},
      onDragStart: onDragStart ?? () {},
      microphone: microphone,
      onMicTap: onMicTap ?? () {},
      onSystemAudioTap: onSystemAudioTap ?? () {},
      onCameraTap: onCameraTap ?? () {},
    );

void main() {
  testWidgets('renders the four source modes', (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(), tips));
    expect(find.text('Display'), findsOneWidget);
    expect(find.text('Window'), findsOneWidget);
    expect(find.text('Area'), findsOneWidget);
    expect(find.text('Device'), findsOneWidget);
  });

  testWidgets(
      'shows "No camera", "No microphone", and "No system audio" when nothing is configured',
      (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(), tips));
    expect(find.text('No camera'), findsOneWidget);
    expect(find.text('No microphone'), findsOneWidget);
    expect(find.text('No system audio'), findsOneWidget);
  });

  testWidgets('tapping Window fires onPickMode(window)', (tester) async {
    _wide(tester);
    BarSourceMode? picked;
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(onPickMode: (m) => picked = m), tips));
    await tester.tap(find.text('Window'));
    expect(picked, BarSourceMode.window);
  });

  testWidgets('tapping Device does NOT fire onPickMode (disabled)',
      (tester) async {
    _wide(tester);
    BarSourceMode? picked;
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(onPickMode: (m) => picked = m), tips));
    await tester.tap(find.text('Device'), warnIfMissed: false);
    expect(picked, isNull);
  });

  testWidgets('close button fires onClose', (tester) async {
    _wide(tester);
    var closed = false;
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(onClose: () => closed = true), tips));
    await tester.tap(find.byKey(const Key('bar-close')));
    expect(closed, isTrue);
  });

  testWidgets('tapping the gear fires onGearTap', (tester) async {
    _wide(tester);
    var gearTapped = false;
    final tips = await _allSeenController();
    await tester
        .pumpWidget(_wrap(_bar(onGearTap: () => gearTapped = true), tips));
    await tester.tap(find.byKey(const Key('bar-gear')));
    expect(gearTapped, isTrue);
  });

  testWidgets('dragging the bar fires onDragStart (window move)',
      (tester) async {
    _wide(tester);
    var dragged = false;
    final tips = await _allSeenController();
    await tester
        .pumpWidget(_wrap(_bar(onDragStart: () => dragged = true), tips));
    await tester.drag(find.byType(RecordingBar), const Offset(60, 0));
    expect(dragged, isTrue);
  });
}
