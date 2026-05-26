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

void main() {
  RecordingBar bar({
    void Function(BarSourceMode)? onPickMode,
    VoidCallback? onClose,
    VoidCallback? onGearTap,
    VoidCallback? onDragStart,
    MicrophoneConfig? microphone,
    VoidCallback? onMicTap,
  }) =>
      RecordingBar(
        onPickMode: onPickMode ?? (_) {},
        onClose: onClose ?? () {},
        onGearTap: onGearTap ?? () {},
        onDragStart: onDragStart ?? () {},
        microphone: microphone,
        onMicTap: onMicTap ?? () {},
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders the four source modes', (tester) async {
    _wide(tester);
    await tester.pumpWidget(wrap(bar()));
    expect(find.text('Display'), findsOneWidget);
    expect(find.text('Window'), findsOneWidget);
    expect(find.text('Area'), findsOneWidget);
    expect(find.text('Device'), findsOneWidget);
  });

  testWidgets('shows the three disabled A/V placeholders', (tester) async {
    _wide(tester);
    await tester.pumpWidget(wrap(bar()));
    expect(find.text('No camera'), findsOneWidget);
    expect(find.text('No microphone'), findsOneWidget);
    expect(find.text('No system audio'), findsOneWidget);
  });

  testWidgets('tapping Window fires onPickMode(window)', (tester) async {
    _wide(tester);
    BarSourceMode? picked;
    await tester.pumpWidget(wrap(bar(onPickMode: (m) => picked = m)));
    await tester.tap(find.text('Window'));
    expect(picked, BarSourceMode.window);
  });

  testWidgets('tapping Device does NOT fire onPickMode (disabled)',
      (tester) async {
    _wide(tester);
    BarSourceMode? picked;
    await tester.pumpWidget(wrap(bar(onPickMode: (m) => picked = m)));
    await tester.tap(find.text('Device'), warnIfMissed: false);
    expect(picked, isNull);
  });

  testWidgets('close button fires onClose', (tester) async {
    _wide(tester);
    var closed = false;
    await tester.pumpWidget(wrap(bar(onClose: () => closed = true)));
    await tester.tap(find.byKey(const Key('bar-close')));
    expect(closed, isTrue);
  });

  testWidgets('tapping the gear fires onGearTap', (tester) async {
    _wide(tester);
    var gearTapped = false;
    await tester.pumpWidget(wrap(bar(onGearTap: () => gearTapped = true)));
    await tester.tap(find.byKey(const Key('bar-gear')));
    expect(gearTapped, isTrue);
  });

  testWidgets('dragging the bar fires onDragStart (window move)',
      (tester) async {
    _wide(tester);
    var dragged = false;
    await tester.pumpWidget(wrap(bar(onDragStart: () => dragged = true)));
    await tester.drag(find.byType(RecordingBar), const Offset(60, 0));
    expect(dragged, isTrue);
  });
}
