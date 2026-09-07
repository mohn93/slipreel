import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/license_store.dart';
import 'package:screen_recorder/state/permission_prompt_log.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/widgets/request_permission.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  _FakePlatform(this.screenRec);
  final PermissionStatus screenRec;
  @override
  Future<PermissionStatus> requestScreenRecordingPermission() async => screenRec;
}

Widget _host(PermissionStatus requestResult, PermissionPromptLog log) =>
    ProviderScope(
      overrides: [
        permissionsControllerProvider.overrideWith(
          (ref) => PermissionsController(_FakePlatform(requestResult)),
        ),
        permissionPromptLogProvider.overrideWithValue(log),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => requestPermissionWithGuide(
                  context, ref, PermissionKind.screenRecording),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

const _sheetTitle = 'Screen Recording permission required';

void main() {
  testWidgets('first ask (never requested) suppresses the sheet — macOS '
      'shows its own prompt, no double dialog', (tester) async {
    final log = PermissionPromptLog(InMemorySecureKV()); // not yet asked
    await tester.pumpWidget(_host(PermissionStatus.denied, log));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(_sheetTitle), findsNothing);
  });

  testWidgets('repeat ask (already requested) + not granted opens the guide '
      'sheet', (tester) async {
    final log = PermissionPromptLog(InMemorySecureKV());
    await log.markScreenRecordingRequested(); // macOS will no longer prompt
    await tester.pumpWidget(_host(PermissionStatus.denied, log));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(_sheetTitle), findsOneWidget);
  });

  testWidgets('a granted result never shows the sheet', (tester) async {
    final log = PermissionPromptLog(InMemorySecureKV());
    await log.markScreenRecordingRequested();
    await tester.pumpWidget(_host(PermissionStatus.granted, log));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(_sheetTitle), findsNothing);
  });

  testWidgets('the first ask records the request so the next one guides',
      (tester) async {
    final log = PermissionPromptLog(InMemorySecureKV());
    await tester.pumpWidget(_host(PermissionStatus.denied, log));

    // First tap: no sheet, but the request is now recorded.
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(_sheetTitle), findsNothing);
    expect(await log.screenRecordingRequested(), isTrue);

    // Second tap: macOS won't prompt again, so the guide sheet appears.
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(_sheetTitle), findsOneWidget);
  });
}
