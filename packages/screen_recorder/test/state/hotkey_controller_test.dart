import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/hotkey_controller.dart';
import 'package:screen_recorder/state/recording_action_router.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  final _controller = StreamController<Map<dynamic, dynamic>>.broadcast();
  int registerCalls = 0, unregisterCalls = 0;
  @override
  Future<void> registerRecordingHotkeys() async => registerCalls++;
  @override
  Future<void> unregisterRecordingHotkeys() async => unregisterCalls++;
  @override
  Stream<Map<dynamic, dynamic>> get hotkeyEvents => _controller.stream;
  void emit(Map<dynamic, dynamic> e) => _controller.add(e);
}

class _RecordingActions {
  int starts = 0, stops = 0, pauses = 0;
}

class _FakeRouter implements RecordingActionRouter {
  _FakeRouter(this.actions);
  final _RecordingActions actions;
  @override
  Future<void> start(BuildContext _) async => actions.starts++;
  @override
  Future<void> stop() async => actions.stops++;
  @override
  Future<void> pauseOrResume() async => actions.pauses++;
}

void main() {
  test('register on construction; unregister on dispose', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    expect(fake.registerCalls, 1);
    await ctrl.dispose();
    expect(fake.unregisterCalls, 1);
  });

  test('start action routes to router.start', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => _MockContext());
    await Future<void>.delayed(Duration.zero);
    fake.emit({'action': 'start'});
    await Future<void>.delayed(Duration.zero);
    expect(actions.starts, 1);
    await ctrl.dispose();
  });

  test('stop action routes to router.stop', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    fake.emit({'action': 'stop'});
    await Future<void>.delayed(Duration.zero);
    expect(actions.stops, 1);
    await ctrl.dispose();
  });

  test('pauseToggle action routes to pauseOrResume', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    fake.emit({'action': 'pauseToggle'});
    await Future<void>.delayed(Duration.zero);
    expect(actions.pauses, 1);
    await ctrl.dispose();
  });

  test('conflict events do not throw and do not route', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    fake.emit({'event': 'conflict', 'id': 1});
    await Future<void>.delayed(Duration.zero);
    expect(actions.starts, 0);
    expect(actions.stops, 0);
    expect(actions.pauses, 0);
    await ctrl.dispose();
  });
}

/// A minimal BuildContext stub for tests that need to pass non-null to start().
class _MockContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
