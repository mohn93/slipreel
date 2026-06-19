import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/permission_status_row.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('granted shows a check and no buttons', (tester) async {
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.microphone,
      label: 'Microphone',
      subtitle: 'For voice.',
      status: PermissionStatus.granted,
      onGrant: () {},
      onOpenSettings: () {},
    )));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('Grant'), findsNothing);
  });

  testWidgets('notDetermined shows Grant and fires onGrant', (tester) async {
    var granted = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.camera,
      label: 'Camera',
      subtitle: 'For webcam.',
      status: PermissionStatus.notDetermined,
      onGrant: () => granted = true,
      onOpenSettings: () {},
    )));
    await tester.tap(find.text('Grant'));
    expect(granted, isTrue);
  });

  testWidgets('denied shows Open System Settings and fires the callback',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.accessibility,
      label: 'Accessibility',
      subtitle: 'For clicks.',
      status: PermissionStatus.denied,
      onGrant: () {},
      onOpenSettings: () => opened = true,
    )));
    await tester.tap(find.text('Open System Settings'));
    expect(opened, isTrue);
  });
}
