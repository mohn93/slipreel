import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

class FormatPicker extends StatelessWidget {
  const FormatPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ExportFormat value;
  final ValueChanged<ExportFormat> onChanged;

  static const _options = [
    (value: ExportFormat.mp4, label: 'MP4', tooltip: null),
    (value: ExportFormat.gif, label: 'GIF', tooltip: null),
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
            Icon(
              Icons.videocam_outlined,
              size: 14,
              color: kTextPrimary,
            ),
            Text(
              'Format',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ExportSegmentedButton<ExportFormat>(
          options: _options,
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
