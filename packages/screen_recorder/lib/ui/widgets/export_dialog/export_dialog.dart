import 'package:flutter/material.dart';
import 'package:slipreel_engine/export/export_estimator.dart';
import 'package:slipreel_engine/models/compression_bitrate.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/compression_picker.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/destination_picker.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/estimation_line.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/format_picker.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/frame_rate_picker.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/resolution_picker.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/shareable_link_panel.dart';

/// GIF-specific frame rate options. 60/50 are dropped because they
/// produce very large GIFs; 15 is added as a useful middle value.
/// Kept separate from [kFrameRateOptions] to avoid leaking GIF-only
/// values into the MP4 picker.
const _kGifFrameRateOptions = <int>[30, 25, 24, 20, 15, 10];

/// The default frame rate used when switching to GIF and the current
/// frame rate is not in [_kGifFrameRateOptions].
const _kGifDefaultFrameRate = 10;

/// The default frame rate used when switching back to MP4 and the current
/// frame rate is not in [kFrameRateOptions] (e.g. after a GIF→MP4 round-trip).
const _kMp4DefaultFrameRate = 30;

class ExportDialog extends StatefulWidget {
  const ExportDialog({
    super.key,
    required this.initialSettings,
    required this.sourceVideoSize,
    required this.videoDuration,
    this.audioBitrateKbps,
    this.estimator = const ExportEstimator(),
    this.onRevealLastExport,
  });

  /// Defaults loaded from `ExportSettingsStore`. Used as the starting
  /// state for the dialog's internal [ExportSettings].
  final ExportSettings initialSettings;

  /// Pixel dimensions of the source recording — drives 4K-disable and
  /// the "WxH" sub-label under the resolution picker.
  final Size sourceVideoSize;

  /// Length of the source clip — drives the estimation line.
  final Duration videoDuration;

  /// Source audio bitrate (kbps) from `ffmpegProbe`. Added to the size
  /// estimate for MP4 because the encoder muxes audio with `-c:a copy`.
  /// Null if the source has no audio stream or the probe couldn't tell.
  final int? audioBitrateKbps;

  final ExportEstimator estimator;

  /// When non-null, the destination row's reveal-in-finder button is
  /// rendered. Null after a fresh boot (nothing to reveal yet).
  final VoidCallback? onRevealLastExport;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  late ExportSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  // ── Derived state helpers ─────────────────────────────────────────────

  bool get _isShareableLink =>
      _settings.destination == ExportDestination.shareableLink;

  List<int> get _frameRateOptions =>
      _settings.format == ExportFormat.gif ? _kGifFrameRateOptions : kFrameRateOptions;

  String get _primaryButtonLabel {
    return switch (_settings.destination) {
      ExportDestination.file => 'Export to file…',
      ExportDestination.clipboard => 'Export to clipboard',
      ExportDestination.shareableLink => 'Export & Share',
    };
  }

  int get _bitrateKbps => effectiveBitrateKbps(
    _settings.resolution,
    _settings.compression,
    _settings.frameRate,
  );

  double get _durationSec => widget.videoDuration.inMilliseconds / 1000.0;

  int get _outputArea {
    final dims = _settings.resolution.dimensionsFor(widget.sourceVideoSize);
    return (dims.width * dims.height).round();
  }

  // ── Mutation handlers ─────────────────────────────────────────────────

  void _onFormatChanged(ExportFormat format) {
    setState(() {
      if (format == ExportFormat.gif) {
        // Snap frame rate to GIF list if the current value isn't in it.
        final snapFps = _kGifFrameRateOptions.contains(_settings.frameRate)
            ? _settings.frameRate
            : _kGifDefaultFrameRate;
        _settings = _settings.copyWith(format: format, frameRate: snapFps);
      } else {
        // Switching back to MP4: snap fps to MP4 list if necessary.
        final snapFps = kFrameRateOptions.contains(_settings.frameRate)
            ? _settings.frameRate
            : _kMp4DefaultFrameRate;
        _settings = _settings.copyWith(format: format, frameRate: snapFps);
      }
    });
  }

  void _onFrameRateChanged(int fps) {
    setState(() {
      _settings = _settings.copyWith(frameRate: fps);
    });
  }

  void _onResolutionChanged(ExportResolution resolution) {
    setState(() {
      _settings = _settings.copyWith(resolution: resolution);
    });
  }

  void _onCompressionChanged(CompressionTier tier) {
    setState(() {
      _settings = _settings.copyWith(compression: tier);
    });
  }

  void _onDestinationChanged(ExportDestination destination) {
    setState(() {
      if (destination == ExportDestination.shareableLink) {
        // Shareable links are hosted VIDEO, always 1080p/60. Force MP4 too:
        // leaving a GIF format here would render the locked 60fps against the
        // GIF-only option list (which lacks 60), tripping FrameRatePicker's
        // assert in debug and showing an unselectable picker in release.
        _settings = _settings.copyWith(
          destination: destination,
          format: ExportFormat.mp4,
          resolution: ExportResolution.r1080p,
          frameRate: 60,
        );
      } else {
        _settings = _settings.copyWith(destination: destination);
      }
    });
  }

  void _onTitleChanged(String title) {
    setState(() {
      _settings = _settings.copyWith(title: title);
    });
  }

  void _onIsPrivateChanged(bool isPrivate) {
    setState(() {
      _settings = _settings.copyWith(isPrivate: isPrivate);
    });
  }

  void _onExport() {
    Navigator.of(context).pop<ExportSettings>(_settings);
  }

  void _onCancel() {
    Navigator.of(context).pop();
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kDialogBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 680, maxWidth: 1100),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTopRow(),
              const SizedBox(height: 20),
              _buildMidRow(),
              const SizedBox(height: 20),
              _buildBottomRow(),
              const SizedBox(height: 8),
              _buildFooterRow(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Row builders ──────────────────────────────────────────────────────

  /// Top row: Format (left) + Frame rate (right).
  Widget _buildTopRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: FormatPicker(
            value: _settings.format,
            onChanged: _onFormatChanged,
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: FrameRatePicker(
            value: _settings.frameRate,
            options: _frameRateOptions,
            onChanged: _onFrameRateChanged,
          ),
        ),
      ],
    );
  }

  /// Mid row: Resolution + Compression — OR — ShareableLinkPanel.
  Widget _buildMidRow() {
    if (_isShareableLink) {
      return ShareableLinkPanel(
        title: _settings.title ?? '',
        isPrivate: _settings.isPrivate,
        onTitleChanged: _onTitleChanged,
        onIsPrivateChanged: _onIsPrivateChanged,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final colWidth = (constraints.maxWidth - 24) / 2;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: colWidth,
              child: ResolutionPicker(
                value: _settings.resolution,
                sourceVideoSize: widget.sourceVideoSize,
                onChanged: _onResolutionChanged,
              ),
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: colWidth,
              child: CompressionPicker(
                value: _settings.compression,
                onChanged: _onCompressionChanged,
              ),
            ),
          ],
        );
      },
    );
  }

  /// Bottom row: Destination (left) + Export + Cancel buttons (right).
  Widget _buildBottomRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: DestinationPicker(
            value: _settings.destination,
            onChanged: _onDestinationChanged,
            onRevealLastExport: widget.onRevealLastExport,
          ),
        ),
        const SizedBox(width: 24),
        _buildActionButtons(),
      ],
    );
  }

  /// Primary export button + Cancel button (stacked vertically, right side).
  Widget _buildActionButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Spacer aligns the action row with the destination picker's first
        // pill; tracks kSectionHeaderHeight (13pt label + 8px gap).
        const SizedBox(height: kSectionHeaderHeight),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            _CancelButton(onTap: _onCancel),
            _ExportButton(
              label: _primaryButtonLabel,
              onTap: _onExport,
            ),
          ],
        ),
      ],
    );
  }

  /// Below bottom row: estimation line OR shareable link footer.
  Widget _buildFooterRow() {
    if (_isShareableLink) {
      return Align(
        alignment: Alignment.centerRight,
        child: Text(
          'Shareable links are always exported as 1080p video at 60fps.',
          key: const ValueKey('shareable_link_footer'),
          style: const TextStyle(color: kTextSecondary, fontSize: 12),
          textAlign: TextAlign.right,
        ),
      );
    }

    return EstimationLine(
      durationSec: _durationSec,
      bitrateKbps: _bitrateKbps,
      format: _settings.format,
      frameRate: _settings.frameRate,
      outputArea: _outputArea,
      audioBitrateKbps: widget.audioBitrateKbps,
      estimator: widget.estimator,
    );
  }
}

// ── Private action button widgets ─────────────────────────────────────────

class _ExportButton extends StatelessWidget {
  const _ExportButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('export_primary_btn'),
      onTap: onTap,
      child: Container(
        height: kSegmentHeight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: kAccent,
          borderRadius: BorderRadius.circular(kSegmentRadius),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('export_cancel_btn'),
      onTap: onTap,
      child: Container(
        height: kSegmentHeight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(kSegmentRadius),
          border: Border.all(color: kBorderSubtle),
        ),
        alignment: Alignment.center,
        child: const Text(
          'Cancel',
          style: TextStyle(
            color: kTextPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
