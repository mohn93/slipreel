import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/ui/widgets/permission_denied_sheet.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';

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
  Future<bool> launch(String url, {
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

void main() {
  late _FakeUrlLauncher fake;

  setUp(() {
    fake = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = fake;
  });

  Future<void> pumpAndShow(WidgetTester tester, PermissionKind kind) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  PermissionDeniedSheet.show(context, kind),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Screen Recording: deep-links to ScreenCapture pane',
      (tester) async {
    await pumpAndShow(tester, PermissionKind.screenRecording);
    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();
    expect(
      fake.lastUrl,
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    );
  });

  testWidgets('Microphone: deep-links to Microphone pane', (tester) async {
    await pumpAndShow(tester, PermissionKind.microphone);
    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();
    expect(
      fake.lastUrl,
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
    );
  });

  testWidgets('Accessibility: deep-links to Accessibility pane',
      (tester) async {
    await pumpAndShow(tester, PermissionKind.accessibility);
    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();
    expect(
      fake.lastUrl,
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
    );
  });

  testWidgets(
      'shows inline error and does NOT pop when launchUrl returns false',
      (tester) async {
    fake.returnValue = false;
    await pumpAndShow(tester, PermissionKind.screenRecording);

    // Sheet is open — no error yet.
    expect(find.textContaining("Couldn't open"), findsNothing);

    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();

    // Error text appears.
    expect(find.textContaining("Couldn't open System Settings"), findsOneWidget);

    // Sheet is still visible (not popped): the title and "Not now" button
    // remain in the tree.
    expect(find.text('Screen Recording permission required'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });
}
