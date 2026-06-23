import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/permission_status_row.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders the leading icon', (tester) async {
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.microphone,
      icon: Icons.mic_none_outlined,
      label: 'Microphone',
      subtitle: 'For voice.',
      status: PermissionStatus.granted,
      onGrant: () {},
      onOpenSettings: () {},
    )));
    expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);
  });

  testWidgets('granted shows a check and no buttons', (tester) async {
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.microphone,
      icon: Icons.mic_none_outlined,
      label: 'Microphone',
      subtitle: 'For voice.',
      status: PermissionStatus.granted,
      onGrant: () {},
      onOpenSettings: () {},
    )));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('Enable'), findsNothing);
  });

  testWidgets('notDetermined shows Enable and fires onGrant', (tester) async {
    var granted = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.camera,
      icon: Icons.videocam_outlined,
      label: 'Camera',
      subtitle: 'For webcam.',
      status: PermissionStatus.notDetermined,
      onGrant: () => granted = true,
      onOpenSettings: () {},
    )));
    await tester.tap(find.text('Enable'));
    expect(granted, isTrue);
  });

  testWidgets('denied shows Open System Settings and fires the callback',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.accessibility,
      icon: Icons.keyboard_outlined,
      label: 'Accessibility',
      subtitle: 'For clicks.',
      status: PermissionStatus.denied,
      onGrant: () {},
      onOpenSettings: () => opened = true,
    )));
    await tester.tap(find.text('Open System Settings'));
    expect(opened, isTrue);
  });

  testWidgets(
      'denied + canRequestWhenDenied shows Enable and fires onGrant (not Settings)',
      (tester) async {
    // Screen Recording reads back as `denied` on first run (CGPreflight is
    // binary — no notDetermined), but the app must still be able to FIRE the
    // request so macOS registers it in the Screen Recording list. The row
    // must offer Enable→onGrant here, not the passive Open-Settings path.
    var granted = false;
    var opened = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.screenRecording,
      icon: Icons.desktop_windows_outlined,
      label: 'Screen Recording',
      subtitle: 'Required.',
      status: PermissionStatus.denied,
      canRequestWhenDenied: true,
      onGrant: () => granted = true,
      onOpenSettings: () => opened = true,
    )));
    expect(find.text('Open System Settings'), findsNothing);
    await tester.tap(find.text('Enable'));
    expect(granted, isTrue);
    expect(opened, isFalse);
  });

  testWidgets(
      'restricted + canRequestWhenDenied shows Enable (not Settings)',
      (tester) async {
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.screenRecording,
      icon: Icons.desktop_windows_outlined,
      label: 'Screen Recording',
      subtitle: 'Required.',
      status: PermissionStatus.restricted,
      canRequestWhenDenied: true,
      onGrant: () {},
      onOpenSettings: () {},
    )));
    expect(find.text('Enable'), findsOneWidget);
    expect(find.text('Open System Settings'), findsNothing);
  });

  testWidgets(
      'denied without the flag keeps the Open System Settings path',
      (tester) async {
    // Camera/mic/accessibility behaviour is unchanged: a real denial still
    // routes to System Settings.
    var opened = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.camera,
      icon: Icons.videocam_outlined,
      label: 'Camera',
      subtitle: 'Optional.',
      status: PermissionStatus.denied,
      onGrant: () {},
      onOpenSettings: () => opened = true,
    )));
    expect(find.text('Enable'), findsNothing);
    await tester.tap(find.text('Open System Settings'));
    expect(opened, isTrue);
  });
}
