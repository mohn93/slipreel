import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Toolbar control for the editor timeline's horizontal zoom plus a
/// preview-playback-speed dropdown.
///
/// Slider position is log-mapped: `slider [0..1] ↔ scale [1..8]` via
/// `scale = pow(8, slider)`. Drag fires
/// `controller.setTimelineScale(newScale, anchorTime: playheadPosition)`.
///
/// The badge on the left is a dropdown ([MenuAnchor]) showing the current
/// preview playback speed (1×/2×/4×/8×). Selecting an option calls
/// [onPreviewSpeedChanged]. The badge no longer resets the timeline zoom.
class TimelineScaleSlider extends ConsumerStatefulWidget {
  const TimelineScaleSlider({
    super.key,
    required this.playheadPosition,
    required this.previewPlaybackSpeed,
    required this.onPreviewSpeedChanged,
    this.width = 180,
  });

  /// Current playhead time. Passed in by the parent (lives on the
  /// playback screen's video controller, not on EditorProjectState).
  final Duration playheadPosition;

  /// Current preview playback speed multiplier (e.g. 1.0, 2.0, 4.0, 8.0).
  /// Session-only state owned by the playback screen.
  final double previewPlaybackSpeed;

  /// Fires when the user picks a new preview speed from the dropdown.
  final ValueChanged<double> onPreviewSpeedChanged;

  final double width;

  /// The discrete options exposed by the preview-speed dropdown.
  static const List<double> previewSpeedOptions = <double>[1.0, 2.0, 4.0, 8.0];

  @override
  ConsumerState<TimelineScaleSlider> createState() =>
      _TimelineScaleSliderState();
}

class _TimelineScaleSliderState extends ConsumerState<TimelineScaleSlider> {
  static double _scaleToSlider(double scale) =>
      math.log(scale) / math.log(8.0);
  static double _sliderToScale(double v) => math.pow(8.0, v).toDouble();

  static String _formatSpeed(double s) {
    // 1.0 → "1×", 2.5 → "2.5×". Avoid trailing ".0" for the common
    // integer-valued options.
    if (s == s.roundToDouble()) {
      return '${s.toStringAsFixed(0)}×';
    }
    return '${s.toStringAsFixed(1)}×';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scale = ref.watch(editorProjectControllerProvider).timelineScale;
    final sliderValue = _scaleToSlider(scale).clamp(0.0, 1.0);

    return SizedBox(
      width: widget.width,
      height: 32,
      child: Row(
        children: [
          MenuAnchor(
            builder: (context, controller, _) {
              return InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatSpeed(widget.previewPlaybackSpeed),
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.expand_more,
                        size: 14,
                        color: palette.textSecondary,
                      ),
                    ],
                  ),
                ),
              );
            },
            menuChildren: [
              for (final v in TimelineScaleSlider.previewSpeedOptions)
                MenuItemButton(
                  trailingIcon: v == widget.previewPlaybackSpeed
                      ? const Icon(Icons.check, size: 16)
                      : const SizedBox(width: 16),
                  onPressed: () => widget.onPreviewSpeedChanged(v),
                  child: Text(_formatSpeed(v)),
                ),
            ],
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbColor: palette.accent,
                activeTrackColor: palette.accentMuted,
                inactiveTrackColor: palette.dividerStrong,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Tooltip(
                message: '${scale.toStringAsFixed(1)}×',
                waitDuration: const Duration(milliseconds: 400),
                child: Slider(
                  value: sliderValue,
                  onChanged: (v) {
                    final next = _sliderToScale(v);
                    ref
                        .read(editorProjectControllerProvider.notifier)
                        .setTimelineScale(
                          next,
                          anchorTime: widget.playheadPosition,
                        );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
