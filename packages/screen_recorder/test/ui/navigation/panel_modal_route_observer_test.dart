import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/ui/navigation/panel_modal_route_observer.dart';

class _FakeChrome implements WindowChrome {
  final List<WindowMode> calls = [];

  @override
  Future<void> setMode(WindowMode mode) async => calls.add(mode);

  @override
  Future<void> setBarSize(double width, double height) async {}

  @override
  Future<String?> showGearMenu() async => null;

  @override
  Future<void> startWindowDrag() async {}
}

void main() {
  testWidgets('blocking modal expands the bar window until dismissed', (
    tester,
  ) async {
    final chrome = _FakeChrome();
    final window = WindowModeController(chrome);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [PanelModalRouteObserver(window)],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Recover unfinished recordings?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(window.state, WindowMode.panel);
    expect(chrome.calls, [WindowMode.panel]);

    // This reproduces the startup race: RecordingBarScreen asks for bar mode
    // on its first frame after the recovery dialog has already been pushed.
    await window.showBar();
    expect(window.state, WindowMode.panel);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(window.state, WindowMode.bar);
    expect(chrome.calls, [WindowMode.panel, WindowMode.bar]);
  });
}
