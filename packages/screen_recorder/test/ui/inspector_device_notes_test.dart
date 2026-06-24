import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/cursor_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/shortcuts_tab.dart';

/// A device recording (iPhone/iPad over USB) carries no cursor / click /
/// keystroke data, so the Cursor and Shortcuts tabs must replace their
/// controls with a clear "not available" note. These tabs early-return the
/// note before touching any provider, so no provider overrides are needed.
Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('CursorTab shows an unavailable note for device recordings',
      (tester) async {
    await tester.pumpWidget(
        _host(const CursorTab(canHideCursor: false, isDevice: true)));

    expect(find.byType(InspectorPlaceholder), findsOneWidget);
    expect(
        find.text('Not available for iPhone/iPad recordings'), findsOneWidget);
    // The real cursor controls are not rendered.
    expect(find.text('Cursor size'), findsNothing);
  });

  testWidgets('ShortcutsTab shows an unavailable note for device recordings',
      (tester) async {
    await tester.pumpWidget(
        _host(const ShortcutsTab(hasKeystrokeData: false, isDevice: true)));

    expect(find.byType(InspectorPlaceholder), findsOneWidget);
    expect(
        find.text('Not available for iPhone/iPad recordings'), findsOneWidget);
    // The real shortcuts controls are not rendered.
    expect(find.text('Show shortcuts'), findsNothing);
  });

  testWidgets('InspectorPlaceholder centers both the title and the body',
      (tester) async {
    // The title wraps to two lines in the narrow inspector; it must be
    // centre-aligned like the body, not left-aligned.
    const title = 'Not available for iPhone/iPad recordings';
    const body = 'Some explanatory text long enough to wrap onto a few lines '
        'inside the inspector panel.';
    await tester.pumpWidget(_host(const InspectorPlaceholder(
      icon: Icons.keyboard_outlined,
      title: title,
      body: body,
    )));

    expect(tester.widget<Text>(find.text(title)).textAlign, TextAlign.center);
    expect(tester.widget<Text>(find.text(body)).textAlign, TextAlign.center);
  });
}
