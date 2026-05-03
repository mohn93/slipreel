import 'package:flutter/material.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

const Color _kTitleColor = Color(0xFFE8E8EA);
const Color _kIconColor = Color(0xFFE8E8EA);

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
          children: const [
            Icon(
              Icons.videocam_outlined,
              size: 14,
              color: _kIconColor,
            ),
            SizedBox(width: 6),
            Text(
              'Format',
              style: TextStyle(
                color: _kTitleColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ExportSegmentedButton<ExportFormat>(
          options: _options,
          selected: value,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
