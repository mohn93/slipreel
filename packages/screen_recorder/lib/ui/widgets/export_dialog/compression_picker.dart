import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

const _kSpeedDisclaimer = 'Quality setting does not impact export speed.';

const _kDescriptions = {
  CompressionTier.studio:
      'Highest quality. Best for archival or further editing.',
  CompressionTier.socialMedia:
      'Optimized for Twitter, LinkedIn, and similar uploads.',
  CompressionTier.web:
      'Good for directly playing on websites. Compression is slightly visible, but not distracting.',
  CompressionTier.webLow:
      'Aggressive compression. Smaller files, more visible artifacts.',
};

class CompressionPicker extends StatelessWidget {
  const CompressionPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final CompressionTier value;
  final ValueChanged<CompressionTier> onChanged;

  static const _options = [
    (value: CompressionTier.studio, label: 'Studio', tooltip: null),
    (
      value: CompressionTier.socialMedia,
      label: 'Social Media',
      tooltip: null,
    ),
    (value: CompressionTier.web, label: 'Web', tooltip: null),
    (value: CompressionTier.webLow, label: 'Web (Low)', tooltip: null),
  ];

  @override
  Widget build(BuildContext context) {
    final description = _kDescriptions[value]!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          spacing: 6,
          children: const [
            Icon(Icons.compress_outlined, size: 14, color: kTextPrimary),
            Text(
              'Compression',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ExportSegmentedButton<CompressionTier>(
          options: _options,
          value: value,
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
        Text(
          description,
          key: const ValueKey('compression_description'),
          style: const TextStyle(color: kTextSecondary, fontSize: 12),
        ),
        const SizedBox(height: 4),
        const Text(
          _kSpeedDisclaimer,
          key: ValueKey('compression_speed_disclaimer'),
          style: TextStyle(color: kTextSecondary, fontSize: 12),
        ),
      ],
    );
  }
}
