import 'package:flutter/material.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

const Color _kTitleColor = Color(0xFFE8E8EA);
const Color _kIconColor = Color(0xFFE8E8EA);
const Color _kSubtitleColor = Color(0xFF8C8C95);

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
          children: const [
            Icon(Icons.compress_outlined, size: 14, color: _kIconColor),
            SizedBox(width: 6),
            Text(
              'Compression',
              style: TextStyle(
                color: _kTitleColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ExportSegmentedButton<CompressionTier>(
          options: _options,
          selected: value,
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
        Text(
          description,
          key: const ValueKey('compression_description'),
          style: const TextStyle(color: _kSubtitleColor, fontSize: 12),
        ),
        const SizedBox(height: 4),
        const Text(
          _kSpeedDisclaimer,
          key: ValueKey('compression_speed_disclaimer'),
          style: TextStyle(color: _kSubtitleColor, fontSize: 12),
        ),
      ],
    );
  }
}
