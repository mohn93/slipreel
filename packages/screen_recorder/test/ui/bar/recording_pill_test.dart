import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/ui/bar/recording_pill.dart';

Widget _h({required RecordingStatus status, required Duration elapsed,
           VoidCallback? onStop, VoidCallback? onPauseOrResume}) {
  return MaterialApp(
    home: Scaffold(
      body: RecordingPill(
        status: status,
        elapsed: elapsed,
        onStop: onStop ?? () {},
        onPauseOrResume: onPauseOrResume ?? () {},
      ),
    ),
  );
}

void main() {
  testWidgets('shows the elapsed time as m:ss', (tester) async {
    await tester.pumpWidget(_h(
        status: RecordingStatus.recording,
        elapsed: const Duration(seconds: 65)));
    expect(find.text('1:05'), findsOneWidget);
  });

  testWidgets('tapping stop fires onStop', (tester) async {
    var stopped = false;
    await tester.pumpWidget(_h(
        status: RecordingStatus.recording,
        elapsed: Duration.zero,
        onStop: () => stopped = true));
    await tester.tap(find.byKey(const Key('pill-stop')));
    expect(stopped, isTrue);
  });

  testWidgets('shows Pause button when recording', (tester) async {
    await tester.pumpWidget(_h(
        status: RecordingStatus.recording, elapsed: const Duration(seconds: 5)));
    expect(find.byKey(const Key('pill-pause')), findsOneWidget);
    expect(find.byKey(const Key('pill-resume')), findsNothing);
  });

  testWidgets('shows Resume button when paused', (tester) async {
    await tester.pumpWidget(_h(
        status: RecordingStatus.paused, elapsed: const Duration(seconds: 5)));
    expect(find.byKey(const Key('pill-resume')), findsOneWidget);
    expect(find.byKey(const Key('pill-pause')), findsNothing);
  });

  testWidgets('Pause tap calls onPauseOrResume', (tester) async {
    int taps = 0;
    await tester.pumpWidget(_h(
        status: RecordingStatus.recording,
        elapsed: Duration.zero,
        onPauseOrResume: () => taps++));
    await tester.tap(find.byKey(const Key('pill-pause')));
    expect(taps, 1);
  });
}
