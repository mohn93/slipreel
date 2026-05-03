import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/destination_picker.dart';

void main() {
  Widget build({
    required ExportDestination value,
    required ValueChanged<ExportDestination> onChanged,
    VoidCallback? onRevealLastExport,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: DestinationPicker(
          value: value,
          onChanged: onChanged,
          onRevealLastExport: onRevealLastExport,
        ),
      ),
    );
  }

  testWidgets('renders File / Clipboard / Shareable link options',
      (tester) async {
    await tester.pumpWidget(
      build(value: ExportDestination.file, onChanged: (_) {}),
    );
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Clipboard'), findsOneWidget);
    expect(find.text('Shareable link'), findsOneWidget);
  });

  testWidgets('shows Destination section header', (tester) async {
    await tester.pumpWidget(
      build(value: ExportDestination.file, onChanged: (_) {}),
    );
    expect(find.text('Destination'), findsOneWidget);
  });

  testWidgets('tapping Clipboard fires onChanged with clipboard',
      (tester) async {
    ExportDestination? fired;
    await tester.pumpWidget(
      build(
        value: ExportDestination.file,
        onChanged: (v) => fired = v,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('seg_btn_ExportDestination.clipboard')),
    );
    await tester.pump();
    expect(fired, ExportDestination.clipboard);
  });

  testWidgets('tapping Shareable link fires onChanged with shareableLink',
      (tester) async {
    ExportDestination? fired;
    await tester.pumpWidget(
      build(
        value: ExportDestination.file,
        onChanged: (v) => fired = v,
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey('seg_btn_ExportDestination.shareableLink'),
      ),
    );
    await tester.pump();
    expect(fired, ExportDestination.shareableLink);
  });

  testWidgets('reveal button is not rendered when callback is null',
      (tester) async {
    await tester.pumpWidget(
      build(value: ExportDestination.file, onChanged: (_) {}),
    );
    expect(find.byKey(const ValueKey('reveal_in_finder_btn')), findsNothing);
  });

  testWidgets('reveal button appears when onRevealLastExport is provided',
      (tester) async {
    await tester.pumpWidget(
      build(
        value: ExportDestination.file,
        onChanged: (_) {},
        onRevealLastExport: () {},
      ),
    );
    expect(
      find.byKey(const ValueKey('reveal_in_finder_btn')),
      findsOneWidget,
    );
  });

  testWidgets('tapping reveal button fires the callback', (tester) async {
    var revealCalled = false;
    await tester.pumpWidget(
      build(
        value: ExportDestination.file,
        onChanged: (_) {},
        onRevealLastExport: () => revealCalled = true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reveal_in_finder_btn')));
    await tester.pump();
    expect(revealCalled, isTrue);
  });
}
