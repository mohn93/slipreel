import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Toolbar control for the editor timeline's horizontal zoom.
///
/// Slider position is log-mapped: `slider [0..1] ↔ scale [1..8]` via
/// `scale = pow(8, slider)`. Drag fires
/// `controller.setTimelineScale(newScale, anchorTime: playheadPosition)`.
/// Tapping the "1×" label on the left animates the scale back to 1.0
/// over 200 ms easeOutQuint — the one place this widget animates.
class TimelineScaleSlider extends ConsumerStatefulWidget {
  const TimelineScaleSlider({
    super.key,
    required this.playheadPosition,
    this.width = 140,
  });

  /// Current playhead time. Passed in by the parent (lives on the
  /// playback screen's video controller, not on EditorProjectState).
  final Duration playheadPosition;
  final double width;

  @override
  ConsumerState<TimelineScaleSlider> createState() =>
      _TimelineScaleSliderState();
}

class _TimelineScaleSliderState extends ConsumerState<TimelineScaleSlider>
    with SingleTickerProviderStateMixin {
  AnimationController? _resetAc;

  static double _scaleToSlider(double scale) =>
      math.log(scale) / math.log(8.0);
  static double _sliderToScale(double v) => math.pow(8.0, v).toDouble();

  void _resetToFit() {
    final ctl = ref.read(editorProjectControllerProvider.notifier);
    final from = ref.read(editorProjectControllerProvider).timelineScale;
    if (from == 1.0) return;
    _resetAc?.dispose();
    final ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    final tween = Tween<double>(begin: from, end: 1.0)
        .chain(CurveTween(curve: Curves.easeOutQuint));
    final anim = ac.drive(tween);
    anim.addListener(() {
      ctl.setTimelineScale(anim.value, anchorTime: widget.playheadPosition);
    });
    _resetAc = ac;
    ac.forward().whenComplete(() {
      // Only this branch may dispose `ac` if it is still the latest
      // animation. `_resetToFit` pre-emptively disposes any in-flight
      // `_resetAc` before starting a new one, and `State.dispose`
      // disposes whatever `_resetAc` points to on unmount. If
      // `_resetAc != ac` here, one of those paths has already disposed
      // `ac` — a second dispose would assert.
      if (identical(_resetAc, ac)) {
        _resetAc = null;
        ac.dispose();
      }
    });
  }

  @override
  void dispose() {
    _resetAc?.dispose();
    super.dispose();
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _resetToFit,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '1×',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ),
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
