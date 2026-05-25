import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder/ui/bar/recording_pill.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';

class _FakeChrome implements WindowChrome {
  final List<WindowMode> calls = [];
  @override
  Future<void> setMode(WindowMode mode) async => calls.add(mode);
}

// The RecordingBar is a wide horizontal Row; the default 800px test surface
// overflows it. Match the existing recording_bar_test.dart pattern.
void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('bar mode renders the RecordingBar', (tester) async {
    _wide(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [windowChromeProvider.overrideWithValue(_FakeChrome())],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();
    expect(find.byType(RecordingBar), findsOneWidget);
    expect(find.byType(RecordingPill), findsNothing);
  });

  testWidgets('pill mode renders the RecordingPill', (tester) async {
    _wide(tester);
    late WidgetRef capturedRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [windowChromeProvider.overrideWithValue(_FakeChrome())],
      child: MaterialApp(
        home: Consumer(builder: (c, ref, _) {
          capturedRef = ref;
          return const RecordingBarScreen();
        }),
      ),
    ));
    await tester.pump();
    await capturedRef.read(windowModeControllerProvider.notifier).showPill();
    await tester.pump();
    expect(find.byType(RecordingPill), findsOneWidget);
    expect(find.byType(RecordingBar), findsNothing);
  });
}
