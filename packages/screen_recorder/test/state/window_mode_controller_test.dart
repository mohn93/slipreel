import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';

class _FakeChrome implements WindowChrome {
  final List<WindowMode> calls = [];
  @override
  Future<void> setMode(WindowMode mode) async => calls.add(mode);
  @override
  Future<String?> showGearMenu() async => null;
  @override
  Future<void> startWindowDrag() async {}
  @override
  Future<void> setBarSize(double width, double height) async {}
}

void main() {
  test('starts in bar mode without touching chrome', () {
    final chrome = _FakeChrome();
    final c = WindowModeController(chrome);
    expect(c.state, WindowMode.bar);
    expect(chrome.calls, isEmpty);
  });

  test('showPill / showPanel / showBar set state and call chrome once each',
      () async {
    final chrome = _FakeChrome();
    final c = WindowModeController(chrome);

    await c.showPill();
    expect(c.state, WindowMode.pill);

    await c.showPanel();
    expect(c.state, WindowMode.panel);

    await c.showBar();
    expect(c.state, WindowMode.bar);

    expect(chrome.calls,
        [WindowMode.pill, WindowMode.panel, WindowMode.bar]);
  });

  test('repeating the current mode is a no-op (no duplicate chrome call)',
      () async {
    final chrome = _FakeChrome();
    final c = WindowModeController(chrome);
    await c.showBar(); // already bar
    expect(chrome.calls, isEmpty);
  });
}
