import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/state/app_menu_actions.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';

class _FakeChrome implements WindowChrome {
  final modes = <WindowMode>[];
  @override
  Future<void> setMode(WindowMode mode) async => modes.add(mode);
  @override
  Future<String?> showGearMenu() async => null;
  @override
  Future<void> startWindowDrag() async {}
  @override
  Future<void> setBarSize(double width, double height) async {}
}

class _FakeLicensing extends StateNotifier<EntitlementState>
    implements LicensingController {
  _FakeLicensing() : super(const EntitlementSignedOut());
  int accountCalls = 0;
  @override
  Future<bool> openAccount() async {
    accountCalls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  // GlobalKey.currentState touches WidgetsBinding.instance, so the binding
  // must exist even for these non-widget tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manageAccount opens the web account page', () async {
    final licensing = _FakeLicensing();
    final c = ProviderContainer(overrides: [
      licensingControllerProvider.overrideWith((ref) => licensing),
    ]);
    addTearDown(c.dispose);

    await c.read(appMenuActionsProvider).manageAccount();
    expect(licensing.accountCalls, 1);
  });

  test('openSettings is a safe no-op with no navigator (no window churn)',
      () async {
    final chrome = _FakeChrome();
    final c = ProviderContainer(overrides: [
      windowChromeProvider.overrideWithValue(chrome),
    ]);
    addTearDown(c.dispose);

    // rootNavigatorKey has no currentState in a plain unit test, so
    // openSettings returns before touching the window — no mode changes.
    await c.read(appMenuActionsProvider).openSettings();
    expect(chrome.modes, isEmpty);
  });
}
