import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/wake_modal.dart';

Widget _harness({required Duration auto, required VoidCallback onPrimary,
                  required VoidCallback onSecondary}) {
  return MaterialApp(
    home: Scaffold(
      body: WakeModal(
        title: 'Welcome back',
        body: 'Your recording was paused.',
        primaryLabel: 'Resume',
        secondaryLabel: 'Stop & save',
        autoStopAfter: auto,
        onPrimary: onPrimary,
        onSecondary: onSecondary,
      ),
    ),
  );
}

void main() {
  testWidgets('primary button triggers onPrimary', (tester) async {
    int p = 0, s = 0;
    await tester.pumpWidget(_harness(
        auto: const Duration(seconds: 60),
        onPrimary: () => p++,
        onSecondary: () => s++));
    await tester.tap(find.text('Resume'));
    expect(p, 1);
    expect(s, 0);
  });

  testWidgets('secondary button triggers onSecondary', (tester) async {
    int p = 0, s = 0;
    await tester.pumpWidget(_harness(
        auto: const Duration(seconds: 60),
        onPrimary: () => p++,
        onSecondary: () => s++));
    await tester.tap(find.text('Stop & save'));
    expect(p, 0);
    expect(s, 1);
  });

  testWidgets('auto-stop fires onSecondary after the timeout',
      (tester) async {
    int s = 0;
    await tester.pumpWidget(_harness(
        auto: const Duration(seconds: 2),
        onPrimary: () {},
        onSecondary: () => s++));
    await tester.pump(const Duration(seconds: 3));
    expect(s, 1);
  });
}
