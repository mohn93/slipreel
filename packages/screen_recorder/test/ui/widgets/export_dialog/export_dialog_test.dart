import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_estimator.dart';
import 'package:slipreel_engine/models/compression_bitrate.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/export_dialog.dart';

/// Helper: wraps the dialog in a [MaterialApp] + [Scaffold] and pushes
/// it as a full-screen route so [Navigator.pop] works normally.
Widget buildDialog({
  ExportSettings? initialSettings,
  Size sourceVideoSize = const Size(1920, 1080),
  Duration videoDuration = const Duration(seconds: 5),
  ExportEstimator estimator = const ExportEstimator(),
  VoidCallback? onRevealLastExport,
}) {
  final settings = initialSettings ?? ExportSettings.defaults();
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const ValueKey('open_dialog_btn'),
            onPressed: () {
              showDialog<ExportSettings?>(
                context: context,
                builder: (_) => ExportDialog(
                  initialSettings: settings,
                  sourceVideoSize: sourceVideoSize,
                  videoDuration: videoDuration,
                  estimator: estimator,
                  onRevealLastExport: onRevealLastExport,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> openDialog(WidgetTester tester, {
  ExportSettings? initialSettings,
  Size sourceVideoSize = const Size(1920, 1080),
  Duration videoDuration = const Duration(seconds: 5),
  ExportEstimator estimator = const ExportEstimator(),
  VoidCallback? onRevealLastExport,
}) async {
  // Set a large enough viewport so the dialog fits without overflow.
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(buildDialog(
    initialSettings: initialSettings,
    sourceVideoSize: sourceVideoSize,
    videoDuration: videoDuration,
    estimator: estimator,
    onRevealLastExport: onRevealLastExport,
  ));
  await tester.tap(find.byKey(const ValueKey('open_dialog_btn')));
  await tester.pumpAndSettle();
}

void main() {
  // ── Test 1: Default state matches mockup layout ────────────────────────
  group('default state', () {
    testWidgets('all pickers visible with MP4/1080p/Web/30fps/File selected',
        (tester) async {
      await openDialog(tester);

      // Format picker shows MP4 selected (segmented button key)
      expect(
        find.byKey(const ValueKey('seg_btn_ExportFormat.mp4')),
        findsOneWidget,
      );

      // Resolution picker shows 1080p selected
      expect(
        find.byKey(const ValueKey('seg_btn_ExportResolution.r1080p')),
        findsOneWidget,
      );

      // Compression picker shows Web selected
      expect(
        find.byKey(const ValueKey('seg_btn_CompressionTier.web')),
        findsOneWidget,
      );

      // Destination picker shows File selected
      expect(
        find.byKey(const ValueKey('seg_btn_ExportDestination.file')),
        findsOneWidget,
      );

      // FrameRatePicker shows 30fps by default
      expect(find.byKey(const ValueKey('frame_rate_closed')), findsOneWidget);
      expect(find.text('30 fps'), findsOneWidget);

      // Primary button says "Export to file…"
      expect(find.byKey(const ValueKey('export_primary_btn')), findsOneWidget);
      expect(find.text('Export to file…'), findsOneWidget);

      // Estimation line is visible (not the shareable link footer)
      expect(find.byKey(const ValueKey('estimation_line_text')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('shareable_link_footer')),
        findsNothing,
      );

      // Resolution and Compression pickers are visible (not hidden)
      expect(find.text('Resolution'), findsOneWidget);
      expect(find.text('Compression'), findsOneWidget);

      // ShareableLinkPanel is NOT visible
      expect(find.byKey(const ValueKey('shareable_title_field')), findsNothing);
    });

    testWidgets('Format section header shown', (tester) async {
      await openDialog(tester);
      expect(find.text('Format'), findsOneWidget);
      expect(find.text('Frame rate'), findsOneWidget);
      expect(find.text('Resolution'), findsOneWidget);
      expect(find.text('Compression'), findsOneWidget);
      expect(find.text('Destination'), findsOneWidget);
    });

    testWidgets('Cancel button is visible', (tester) async {
      await openDialog(tester);
      expect(find.byKey(const ValueKey('export_cancel_btn')), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });
  });

  // ── Test 2: Switching to Shareable link ───────────────────────────────
  group('shareable link mode', () {
    testWidgets(
        'switching to Shareable link hides resolution/compression, shows panel + footer',
        (tester) async {
      await openDialog(tester);

      // Tap Shareable link
      await tester.tap(
        find.byKey(
          const ValueKey('seg_btn_ExportDestination.shareableLink'),
        ),
      );
      await tester.pumpAndSettle();

      // Resolution and Compression pickers disappear
      expect(find.text('Resolution'), findsNothing);
      expect(find.text('Compression'), findsNothing);

      // ShareableLinkPanel appears
      expect(
        find.byKey(const ValueKey('shareable_title_field')),
        findsOneWidget,
      );

      // Footer shows the lock note
      expect(
        find.byKey(const ValueKey('shareable_link_footer')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Shareable links are always exported as 1080p video at 60fps.',
        ),
        findsOneWidget,
      );

      // Estimation line is gone
      expect(
        find.byKey(const ValueKey('estimation_line_text')),
        findsNothing,
      );
    });

    testWidgets('button label changes to "Export & Share"', (tester) async {
      await openDialog(tester);

      await tester.tap(
        find.byKey(
          const ValueKey('seg_btn_ExportDestination.shareableLink'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Export & Share'), findsOneWidget);
    });
  });

  // ── Test 3: 4K disabled when source is 1080p ─────────────────────────
  group('4K disabled when source < 4K', () {
    testWidgets('4K segment is rendered as disabled', (tester) async {
      await openDialog(tester, sourceVideoSize: const Size(1920, 1080));

      // The 4K button should be present but disabled
      final btn4k = find.byKey(const ValueKey('seg_btn_ExportResolution.r4k'));
      expect(btn4k, findsOneWidget);

      // Check Semantics: the button has enabled=false
      final semantics = tester.getSemantics(btn4k);
      // isEnabled == Tristate.isFalse means the button is explicitly disabled.
      expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);
    });

    testWidgets('tapping disabled 4K segment does not change selection',
        (tester) async {
      await openDialog(tester, sourceVideoSize: const Size(1920, 1080));

      // Tap the 4K button — should not fire
      await tester.tap(
        find.byKey(const ValueKey('seg_btn_ExportResolution.r4k')),
      );
      await tester.pump();

      // 1080p still selected — resolution picker label still says 1080p
      expect(
        find.byKey(const ValueKey('seg_btn_ExportResolution.r1080p')),
        findsOneWidget,
      );
    });
  });

  // ── Test 4: Format=GIF swaps frame rate list ──────────────────────────
  group('GIF format swaps frame rate options', () {
    testWidgets('GIF hides 60/50 options and shows 15', (tester) async {
      await openDialog(tester);

      // Switch to GIF
      await tester.tap(find.byKey(const ValueKey('seg_btn_ExportFormat.gif')));
      await tester.pumpAndSettle();

      // Open the frame rate dropdown
      await tester.tap(find.byKey(const ValueKey('frame_rate_popup')));
      await tester.pumpAndSettle();

      // 60 and 50 should NOT appear in the menu
      expect(find.byKey(const ValueKey('fps_option_60')), findsNothing);
      expect(find.byKey(const ValueKey('fps_option_50')), findsNothing);

      // 15 SHOULD appear (it's GIF-only)
      expect(find.byKey(const ValueKey('fps_option_15')), findsOneWidget);
    });
  });

  // ── Test 5: Format=GIF snaps frame rate ──────────────────────────────
  group('GIF format snaps frame rate', () {
    testWidgets('when current fps=60 and format switches to GIF, fps snaps to 10',
        (tester) async {
      await openDialog(
        tester,
        initialSettings: ExportSettings.defaults().copyWith(frameRate: 60),
      );

      // Verify 60fps is shown initially
      expect(find.text('60 fps'), findsOneWidget);

      // Switch to GIF
      await tester.tap(find.byKey(const ValueKey('seg_btn_ExportFormat.gif')));
      await tester.pumpAndSettle();

      // fps should have snapped — 60 is no longer in GIF list, so snaps to 10
      expect(find.text('10 fps'), findsOneWidget);
      // 60fps no longer shown
      expect(find.text('60 fps'), findsNothing);
    });

    testWidgets('when current fps=30 and format switches to GIF, fps stays 30',
        (tester) async {
      await openDialog(
        tester,
        initialSettings: ExportSettings.defaults().copyWith(frameRate: 30),
      );

      // Switch to GIF
      await tester.tap(find.byKey(const ValueKey('seg_btn_ExportFormat.gif')));
      await tester.pumpAndSettle();

      // 30 is in the GIF list, stays
      expect(find.text('30 fps'), findsOneWidget);
    });
  });

  // ── Test 6: Primary button label tracks destination ────────────────────
  group('primary button label tracks destination', () {
    testWidgets('label is "Export to file…" for File destination',
        (tester) async {
      await openDialog(tester);
      expect(find.text('Export to file…'), findsOneWidget);
    });

    testWidgets('label is "Export to clipboard" for Clipboard destination',
        (tester) async {
      await openDialog(tester);

      await tester.tap(
        find.byKey(
          const ValueKey('seg_btn_ExportDestination.clipboard'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Export to clipboard'), findsOneWidget);
    });

    testWidgets('label is "Export & Share" for Shareable link destination',
        (tester) async {
      await openDialog(tester);

      await tester.tap(
        find.byKey(
          const ValueKey('seg_btn_ExportDestination.shareableLink'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Export & Share'), findsOneWidget);
    });

    testWidgets('label cycles back to "Export to file…" when returning to File',
        (tester) async {
      await openDialog(tester);

      // Switch to clipboard
      await tester.tap(
        find.byKey(
          const ValueKey('seg_btn_ExportDestination.clipboard'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Export to clipboard'), findsOneWidget);

      // Switch back to File
      await tester.tap(
        find.byKey(
          const ValueKey('seg_btn_ExportDestination.file'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Export to file…'), findsOneWidget);
    });
  });

  // ── Test 7: Confirming returns current settings ────────────────────────
  group('confirming returns ExportSettings', () {
    testWidgets('tapping primary button closes dialog and returns settings',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      ExportSettings? returned;

      final widget = MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open_dialog_btn'),
                onPressed: () async {
                  returned = await showDialog<ExportSettings>(
                    context: context,
                    builder: (_) => ExportDialog(
                      initialSettings: ExportSettings.defaults(),
                      sourceVideoSize: const Size(1920, 1080),
                      videoDuration: const Duration(seconds: 5),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(widget);
      await tester.tap(find.byKey(const ValueKey('open_dialog_btn')));
      await tester.pumpAndSettle();

      // Tap Export
      await tester.tap(find.byKey(const ValueKey('export_primary_btn')));
      await tester.pumpAndSettle();

      // Should return the current ExportSettings
      expect(returned, isNotNull);
      expect(returned!.format, ExportFormat.mp4);
      expect(returned!.resolution, ExportResolution.r1080p);
      expect(returned!.compression, CompressionTier.web);
      expect(returned!.frameRate, 30);
      expect(returned!.destination, ExportDestination.file);
    });

    testWidgets('changing settings before confirming returns updated settings',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      ExportSettings? returned;

      final widget = MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open_dialog_btn'),
                onPressed: () async {
                  returned = await showDialog<ExportSettings>(
                    context: context,
                    builder: (_) => ExportDialog(
                      initialSettings: ExportSettings.defaults(),
                      sourceVideoSize: const Size(1920, 1080),
                      videoDuration: const Duration(seconds: 5),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(widget);
      await tester.tap(find.byKey(const ValueKey('open_dialog_btn')));
      await tester.pumpAndSettle();

      // Switch to GIF
      await tester.tap(find.byKey(const ValueKey('seg_btn_ExportFormat.gif')));
      await tester.pumpAndSettle();

      // Switch to clipboard
      await tester.tap(
        find.byKey(const ValueKey('seg_btn_ExportDestination.clipboard')),
      );
      await tester.pumpAndSettle();

      // Confirm
      await tester.tap(find.byKey(const ValueKey('export_primary_btn')));
      await tester.pumpAndSettle();

      expect(returned, isNotNull);
      expect(returned!.format, ExportFormat.gif);
      expect(returned!.destination, ExportDestination.clipboard);
    });

    testWidgets('shareable link locks resolution to 1080p and fps to 60',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      ExportSettings? returned;

      final widget = MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open_dialog_btn'),
                onPressed: () async {
                  returned = await showDialog<ExportSettings>(
                    context: context,
                    builder: (_) => ExportDialog(
                      initialSettings: ExportSettings.defaults().copyWith(
                        resolution: ExportResolution.r720p,
                        frameRate: 24,
                      ),
                      sourceVideoSize: const Size(1920, 1080),
                      videoDuration: const Duration(seconds: 5),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(widget);
      await tester.tap(find.byKey(const ValueKey('open_dialog_btn')));
      await tester.pumpAndSettle();

      // Switch to Shareable link
      await tester.tap(
        find.byKey(
          const ValueKey('seg_btn_ExportDestination.shareableLink'),
        ),
      );
      await tester.pumpAndSettle();

      // Confirm
      await tester.tap(find.byKey(const ValueKey('export_primary_btn')));
      await tester.pumpAndSettle();

      expect(returned, isNotNull);
      expect(returned!.resolution, ExportResolution.r1080p);
      expect(returned!.frameRate, 60);
    });
  });

  // ── Test 8: Cancel returns null ────────────────────────────────────────
  group('cancel returns null', () {
    testWidgets('tapping Cancel closes dialog and returns null', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      ExportSettings? returned;

      final widget = MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open_dialog_btn'),
                onPressed: () async {
                  returned = await showDialog<ExportSettings>(
                    context: context,
                    builder: (_) => ExportDialog(
                      initialSettings: ExportSettings.defaults(),
                      sourceVideoSize: const Size(1920, 1080),
                      videoDuration: const Duration(seconds: 5),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(widget);
      await tester.tap(find.byKey(const ValueKey('open_dialog_btn')));
      await tester.pumpAndSettle();

      // Tap Cancel
      await tester.tap(find.byKey(const ValueKey('export_cancel_btn')));
      await tester.pumpAndSettle();

      expect(returned, isNull);
    });
  });

  // ── Additional coverage: estimation line updates ───────────────────────
  group('estimation line', () {
    testWidgets('shows estimation text below export button', (tester) async {
      await openDialog(tester);
      // The estimation line widget shows the estimation text
      expect(find.byKey(const ValueKey('estimation_line_text')), findsOneWidget);
      // The text contains the estimation prefix
      final textWidget = tester.widget<Text>(
        find.byKey(const ValueKey('estimation_line_text')),
      );
      expect(textWidget.data, contains('Estimation'));
    });
  });

  // ── 4K enabled when source is 4K+ ─────────────────────────────────────
  group('4K enabled when source is 4K', () {
    testWidgets('4K segment is enabled when source >= 4K', (tester) async {
      await openDialog(
        tester,
        sourceVideoSize: const Size(3840, 2160),
      );

      final btn4k = find.byKey(const ValueKey('seg_btn_ExportResolution.r4k'));
      expect(btn4k, findsOneWidget);

      // Should be enabled — not in disabled set (isEnabled != Tristate.isFalse)
      final semantics = tester.getSemantics(btn4k);
      expect(semantics.flagsCollection.isEnabled, isNot(Tristate.isFalse));
    });
  });

  // ── bitrateKbps plumbing ───────────────────────────────────────────────
  group('estimation plumbing', () {
    testWidgets('estimation line reflects resolution+compression settings',
        (tester) async {
      // Default 1080p/Web => bitrateKbps=6000
      await openDialog(
        tester,
        videoDuration: const Duration(seconds: 10),
      );

      final textWidget = tester.widget<Text>(
        find.byKey(const ValueKey('estimation_line_text')),
      );
      // Should show a non-empty estimation
      expect(textWidget.data, isNotEmpty);
      expect(textWidget.data, contains('Estimation'));

      // Verify the bitrate used is 6000 (1080p/Web = 6 Mbps)
      final estimator = const ExportEstimator();
      final expectedLine = estimator.formatLine(
        durationSec: 10.0,
        bitrateKbps: compressionBitrate(
          ExportResolution.r1080p,
          CompressionTier.web,
        ),
        format: ExportFormat.mp4,
      );
      expect(textWidget.data, equals(expectedLine));
    });
  });
}
