import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/widgets/request_permission.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  _FakePlatform(this.screenRec);
  final PermissionStatus screenRec;
  @override
  Future<PermissionStatus> requestScreenRecordingPermission() async => screenRec;
}

Widget _host(PermissionStatus requestResult) => ProviderScope(
      overrides: [
        permissionsControllerProvider.overrideWith(
          (ref) => PermissionsController(_FakePlatform(requestResult)),
        ),
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

void main() {
  testWidgets('Screen Recording: a non-granted result opens the deny sheet',
      (tester) async {
    await tester.pumpWidget(_host(PermissionStatus.denied));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    // The sheet (which carries "Open System Settings" -> the drag-to-add guide).
    expect(find.text('Screen Recording permission required'), findsOneWidget);
  });

  testWidgets('Screen Recording: a granted result shows no sheet',
      (tester) async {
    await tester.pumpWidget(_host(PermissionStatus.granted));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Screen Recording permission required'), findsNothing);
  });
}
