import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

class DestinationPicker extends StatelessWidget {
  const DestinationPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.onRevealLastExport,
  });

  final ExportDestination value;
  final ValueChanged<ExportDestination> onChanged;

  /// When non-null a "Reveal in Finder" folder-icon button is rendered.
  /// The parent sets this to a real callback after a successful export;
  /// it is null when no export has happened yet.
  final VoidCallback? onRevealLastExport;

  static const _options = [
    (value: ExportDestination.file, label: 'File', tooltip: null),
    (value: ExportDestination.clipboard, label: 'Clipboard', tooltip: null),
    (
      value: ExportDestination.shareableLink,
      label: 'Shareable link',
      tooltip: null,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          spacing: 6,
          children: const [
            Icon(Icons.send_outlined, size: 14, color: kTextPrimary),
            Text(
              'Destination',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: kSegmentHGap,
          children: [
            ExportSegmentedButton<ExportDestination>(
              options: _options,
              value: value,
              onChanged: onChanged,
            ),
            if (onRevealLastExport != null)
              _RevealButton(onTap: onRevealLastExport!),
          ],
        ),
      ],
    );
  }
}

class _RevealButton extends StatelessWidget {
  const _RevealButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Reveal in Finder',
      child: PillSurface(
        key: const ValueKey('reveal_in_finder_btn'),
        width: kSegmentHeight,
        onTap: onTap,
        child: const Icon(
          Icons.folder_outlined,
          size: 16,
          color: kTextPrimary,
        ),
      ),
    );
  }
}
