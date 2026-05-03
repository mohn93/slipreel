import 'package:flutter/material.dart';
import 'package:screen_recorder/export/export_estimator.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';

/// A right-aligned single-line widget that shows the estimated export
/// time and output size. The parent swaps this widget for a different
/// string when destination is Shareable link — this widget itself is
/// destination-agnostic.
class EstimationLine extends StatelessWidget {
  const EstimationLine({
    super.key,
    required this.durationSec,
    required this.bitrateKbps,
    required this.format,
    this.estimator = const ExportEstimator(),
  });

  final double durationSec;
  final int bitrateKbps;
  final ExportFormat format;
  final ExportEstimator estimator;

  @override
  Widget build(BuildContext context) {
    final line = estimator.formatLine(
      durationSec: durationSec,
      bitrateKbps: bitrateKbps,
      format: format,
    );

    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        line,
        key: const ValueKey('estimation_line_text'),
        style: const TextStyle(color: kTextSecondary, fontSize: 12),
        textAlign: TextAlign.right,
      ),
    );
  }
}
