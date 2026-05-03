import 'package:flutter/material.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

const Color _kTitleColor = Color(0xFFE8E8EA);
const Color _kIconColor = Color(0xFFE8E8EA);
const Color _kSubtitleColor = Color(0xFF8C8C95);

class ResolutionPicker extends StatelessWidget {
  const ResolutionPicker({
    super.key,
    required this.value,
    required this.sourceVideoSize,
    required this.onChanged,
  });

  final ExportResolution value;
  final Size sourceVideoSize;
  final ValueChanged<ExportResolution> onChanged;

  static const _k4kTooltip = 'Source resolution is lower than 4K';

  static const _options = [
    (value: ExportResolution.r720p, label: '720p', tooltip: null),
    (value: ExportResolution.r1080p, label: '1080p', tooltip: null),
    (value: ExportResolution.r4k, label: '4K', tooltip: _k4kTooltip),
  ];

  @override
  Widget build(BuildContext context) {
    final is4kAvailable = sourceVideoSize.shortestSide >= 2160;
    final disabled = is4kAvailable ? <ExportResolution>{} : {ExportResolution.r4k};

    final dims = value.dimensionsFor(sourceVideoSize);
    final dimLabel =
        '${dims.width.toInt()}px × ${dims.height.toInt()}px';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: const [
            Icon(Icons.aspect_ratio_outlined, size: 14, color: _kIconColor),
            SizedBox(width: 6),
            Text(
              'Resolution',
              style: TextStyle(
                color: _kTitleColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ExportSegmentedButton<ExportResolution>(
          options: _options,
          selected: value,
          onChanged: onChanged,
          disabled: disabled,
        ),
        const SizedBox(height: 6),
        Text(
          dimLabel,
          key: const ValueKey('resolution_dim_label'),
          style: const TextStyle(
            color: _kSubtitleColor,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
