import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/screens/onboarding/pages/permissions_page.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

PermissionsSnapshot _snap({
  PermissionStatus screen = PermissionStatus.notDetermined,
  PermissionStatus mic = PermissionStatus.notDetermined,
  PermissionStatus ax = PermissionStatus.notDetermined,
}) =>
    PermissionsSnapshot({
      PermissionKind.screenRecording: screen,
      PermissionKind.microphone: mic,
      PermissionKind.accessibility: ax,
    });

class _StubController extends StateNotifier<PermissionsSnapshot>
    implements PermissionsController {
  _StubController(super.s);
  @override
  Future<void> refreshAll() async {}
  @override
  Future<PermissionStatus> request(PermissionKind kind) async =>
      state.byKind[kind] ?? PermissionStatus.unsupported;
}

Future<void> pump(WidgetTester tester, PermissionsSnapshot snapshot) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      permissionsControllerProvider
          .overrideWith((ref) => _StubController(snapshot)),
    ],
    child: MaterialApp(
      home: Scaffold(body: PermissionsPage(onNext: () {})),
    ),
  ));
}

void main() {
  testWidgets('Continue is disabled when Screen Rec is not granted',
      (tester) async {
    await pump(tester, _snap(screen: PermissionStatus.notDetermined));
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'));
    expect(btn.onPressed, isNull);
  });

  testWidgets('Continue is enabled when Screen Rec is granted',
      (tester) async {
    await pump(
        tester,
        _snap(
          screen: PermissionStatus.granted,
          mic: PermissionStatus.denied,
          ax: PermissionStatus.denied,
        ));
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'));
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('Granted rows show a check mark', (tester) async {
    await pump(tester, _snap(mic: PermissionStatus.granted));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
