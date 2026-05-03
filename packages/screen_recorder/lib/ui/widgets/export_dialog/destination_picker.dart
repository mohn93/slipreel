import 'package:flutter/material.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

const Color _kTitleColor = Color(0xFFE8E8EA);
const Color _kIconColor = Color(0xFFE8E8EA);

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
          children: const [
            Icon(Icons.send_outlined, size: 14, color: _kIconColor),
            SizedBox(width: 6),
            Text(
              'Destination',
              style: TextStyle(
                color: _kTitleColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DestinationRow(
              options: _options,
              selected: value,
              onChanged: onChanged,
            ),
            if (onRevealLastExport != null) ...[
              const SizedBox(width: 8),
              _RevealButton(onTap: onRevealLastExport!),
            ],
          ],
        ),
      ],
    );
  }
}

/// The three destination buttons with their leading icons.
class _DestinationRow extends StatelessWidget {
  const _DestinationRow({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<({ExportDestination value, String label, String? tooltip})>
      options;
  final ExportDestination selected;
  final ValueChanged<ExportDestination> onChanged;

  @override
  Widget build(BuildContext context) {
    return ExportSegmentedButton<ExportDestination>(
      options: options,
      selected: selected,
      onChanged: onChanged,
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
      child: GestureDetector(
        key: const ValueKey('reveal_in_finder_btn'),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF22232C),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.folder_outlined,
            size: 16,
            color: Color(0xFFE8E8EA),
          ),
        ),
      ),
    );
  }
}
