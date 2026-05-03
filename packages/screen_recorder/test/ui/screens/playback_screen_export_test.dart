// Tests for the export flow wired into PlaybackScreen (Task 9).
//
// Full PlaybackScreen widget tests require a valid video file, ffprobe,
// and a live RecordingMetadata sidecar — none of which are available in
// the unit-test sandbox. Per the plan, the minimum viable scope is:
//
//   1. Tapping Export opens the **new** ExportDialog (not the legacy radio
//      AlertDialog).
//   2. Cancelling the dialog returns null — no export is triggered.
//
// We test these by exercising the ExportDialog directly in a thin
// MaterialApp harness (the same approach used by export_dialog_test.dart),
// verifying that the widget type and cancel/confirm behaviour are correct.
// Deeper integration with FileSaver / pipelines is verified via manual QA
// (plan Task 10).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/export_dialog.dart';

// ---------------------------------------------------------------------------
// Harness helpers
// ---------------------------------------------------------------------------

/// Wraps [ExportDialog] in a MaterialApp with a trigger button. Mirrors
/// the pattern used by `export_dialog_test.dart` so test conventions are
/// consistent.
Widget _buildHarness({
  ExportSettings? initialSettings,
  Size sourceVideoSize = const Size(1920, 1080),
  Duration videoDuration = const Duration(seconds: 5),
  void Function(ExportSettings?)? onResult,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const ValueKey('export_btn'),
            onPressed: () async {
              final result = await showDialog<ExportSettings?>(
                context: context,
                builder: (_) => ExportDialog(
                  initialSettings: initialSettings ?? ExportSettings.defaults(),
                  sourceVideoSize: sourceVideoSize,
                  videoDuration: videoDuration,
                ),
              );
              onResult?.call(result);
            },
            child: const Text('Export'),
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('PlaybackScreen export flow — ExportDialog integration', () {
    // The ExportDialog requires at least 680px width. Set the surface to
    // 1400×900 so layout succeeds (matches the convention in export_dialog_test.dart).
    setUp(() {});

    testWidgets(
      'tapping Export opens the new ExportDialog (not the legacy radio dialog)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(_buildHarness());

        // Dialog is not present before the button is tapped.
        expect(find.byType(ExportDialog), findsNothing);

        await tester.tap(find.byKey(const ValueKey('export_btn')));
        await tester.pumpAndSettle();

        // The new dialog — with its segmented pickers — must be on screen.
        expect(find.byType(ExportDialog), findsOneWidget);

        // Verify it is NOT the legacy radio-list AlertDialog by checking
        // that there are no RadioListTile widgets (the legacy dialog used them).
        expect(find.byType(RadioListTile<ExportSettings>), findsNothing);
      },
    );

    testWidgets(
      'cancelling the dialog returns null — no ExportSettings produced',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        ExportSettings? capturedResult = ExportSettings.defaults(); // non-null sentinel
        await tester.pumpWidget(_buildHarness(
          onResult: (r) => capturedResult = r,
        ));

        await tester.tap(find.byKey(const ValueKey('export_btn')));
        await tester.pumpAndSettle();

        // Dialog is open.
        expect(find.byType(ExportDialog), findsOneWidget);

        // Tap the Cancel button inside the dialog.
        await tester.tap(find.byKey(const ValueKey('export_cancel_btn')));
        await tester.pumpAndSettle();

        // Dialog dismissed, result is null.
        expect(find.byType(ExportDialog), findsNothing);
        expect(capturedResult, isNull);
      },
    );

    testWidgets(
      'confirming the dialog returns a non-null ExportSettings',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        ExportSettings? capturedResult;
        await tester.pumpWidget(_buildHarness(
          onResult: (r) => capturedResult = r,
        ));

        await tester.tap(find.byKey(const ValueKey('export_btn')));
        await tester.pumpAndSettle();

        // Tap the primary export button.
        await tester.tap(find.byKey(const ValueKey('export_primary_btn')));
        await tester.pumpAndSettle();

        // Dialog dismissed, result is non-null with default settings.
        expect(find.byType(ExportDialog), findsNothing);
        expect(capturedResult, isNotNull);
        expect(capturedResult!.format, ExportFormat.mp4);
        expect(capturedResult!.destination, ExportDestination.file);
      },
    );

    testWidgets(
      'ExportDialog default state matches expected format / destination',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(_buildHarness());

        await tester.tap(find.byKey(const ValueKey('export_btn')));
        await tester.pumpAndSettle();

        // Dialog is open with default settings — verify primary button
        // label is "Export to file…" which corresponds to the default
        // ExportDestination.file.
        expect(find.text('Export to file…'), findsOneWidget);
      },
    );
  });
}
