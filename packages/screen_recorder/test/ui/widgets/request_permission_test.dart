import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/widgets/request_permission.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeUrlLauncher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  String? lastUrl;
  bool returnValue = true;
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    return returnValue;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    lastUrl = url;
    return returnValue;
  }
}

class _FakePlatform extends ScreenRecorderPlatform with MockPlatformInterfaceMixin {
  int guideCalls = 0;
  @override
  Future<void> showScreenRecordingPermissionGuide() async => guideCalls++;
  @override
  Future<PermissionStatus> requestMicrophonePermission() async =>
      PermissionStatus.granted;
}

void main() {
  late _FakeUrlLauncher fakeUrl;
  late _FakePlatform fakePlatform;

  Widget host(PermissionKind kind) => ProviderScope(
        overrides: [
          permissionsControllerProvider
              .overrideWith((ref) => PermissionsController(fakePlatform)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => requestPermissionWithGuide(context, ref, kind),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );

  setUp(() {
    fakeUrl = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = fakeUrl;
    fakePlatform = _FakePlatform();
    ScreenRecorderPlatform.instance = fakePlatform;
  });

  testWidgets('Screen Recording opens the Privacy pane and the floating guide',
      (tester) async {
    await tester.pumpWidget(host(PermissionKind.screenRecording));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(fakeUrl.lastUrl, contains('Privacy_ScreenCapture'));
    expect(fakePlatform.guideCalls, 1);
    // Never a modal sheet (that was the double-prompt bug).
    expect(find.text('Screen Recording permission required'), findsNothing);
  });

  testWidgets('no guide when System Settings fails to open', (tester) async {
    fakeUrl.returnValue = false;
    await tester.pumpWidget(host(PermissionKind.screenRecording));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(fakePlatform.guideCalls, 0);
  });

  testWidgets('other permissions request normally — no Settings, no guide',
      (tester) async {
    await tester.pumpWidget(host(PermissionKind.microphone));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(fakeUrl.lastUrl, isNull);
    expect(fakePlatform.guideCalls, 0);
  });
}
