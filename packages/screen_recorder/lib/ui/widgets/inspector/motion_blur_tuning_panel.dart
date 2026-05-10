import 'package:flutter/material.dart';
import 'package:screen_recorder/effects/motion_blur_tuning.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Live-tunable knobs for the cursor motion-blur path. Each slider
/// drives one field on [MotionBlurTuning]; changes call back to the
/// parent which feeds them to the painter on the next frame.
///
/// Used by the Animation inspector tab and by the motion-blur
/// playground screen.
class MotionBlurTuningPanel extends StatelessWidget {
  const MotionBlurTuningPanel({
    super.key,
    required this.tuning,
    required this.onChanged,
  });

  final MotionBlurTuning tuning;
  final ValueChanged<MotionBlurTuning> onChanged;

  static const _defaults = MotionBlurTuning.defaults;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TuningGroupHeader('Trail length'),
        InspectorSlider(
          label: 'Max exposure (ms) — '
              '${tuning.maxExposureMs.toStringAsFixed(0)}',
          subtitle: 'Virtual shutter window at slider=1.0. Bigger = '
              'more dramatic blur on the same motion.',
          value: tuning.maxExposureMs,
          min: 5,
          max: 200,
          onChanged: (v) => onChanged(tuning.copyWith(maxExposureMs: v)),
          onReset: () => onChanged(
              tuning.copyWith(maxExposureMs: _defaults.maxExposureMs)),
          canReset: tuning.maxExposureMs != _defaults.maxExposureMs,
        ),
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Max trail length (px) — '
              '${tuning.maxTrailPx.toStringAsFixed(0)}',
          subtitle: 'Hard cap on rendered trail length, regardless '
              'of velocity.',
          value: tuning.maxTrailPx,
          min: 20,
          max: 500,
          onChanged: (v) => onChanged(tuning.copyWith(maxTrailPx: v)),
          onReset: () => onChanged(
              tuning.copyWith(maxTrailPx: _defaults.maxTrailPx)),
          canReset: tuning.maxTrailPx != _defaults.maxTrailPx,
        ),
        const SizedBox(height: 24),
        const _TuningGroupHeader('Velocity trigger'),
        InspectorSlider(
          label: 'Trigger low (px/s) — '
              '${tuning.vTriggerLowPxPerSec.toStringAsFixed(0)}',
          subtitle: 'Below this speed no blur draws at all. Slow drag '
              'and hover stay sharp.',
          value: tuning.vTriggerLowPxPerSec,
          min: 0,
          max: 3000,
          onChanged: (v) =>
              onChanged(tuning.copyWith(vTriggerLowPxPerSec: v)),
          onReset: () => onChanged(tuning.copyWith(
              vTriggerLowPxPerSec: _defaults.vTriggerLowPxPerSec)),
          canReset:
              tuning.vTriggerLowPxPerSec != _defaults.vTriggerLowPxPerSec,
        ),
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Trigger high (px/s) — '
              '${tuning.vTriggerHighPxPerSec.toStringAsFixed(0)}',
          subtitle: 'Above this speed the blur is at full strength. '
              'Between low and high the trail length ramps in via '
              'smoothstep.',
          value: tuning.vTriggerHighPxPerSec,
          min: 0,
          max: 5000,
          onChanged: (v) =>
              onChanged(tuning.copyWith(vTriggerHighPxPerSec: v)),
          onReset: () => onChanged(tuning.copyWith(
              vTriggerHighPxPerSec: _defaults.vTriggerHighPxPerSec)),
          canReset:
              tuning.vTriggerHighPxPerSec != _defaults.vTriggerHighPxPerSec,
        ),
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Velocity lookback (ms) — '
              '${tuning.velocityLookbackMs.toStringAsFixed(1)}',
          subtitle: 'Window for the velocity that caps the trail '
              'during deceleration. Longer = smoother decay, '
              'shorter = more reactive.',
          value: tuning.velocityLookbackMs,
          min: 4,
          max: 100,
          onChanged: (v) =>
              onChanged(tuning.copyWith(velocityLookbackMs: v)),
          onReset: () => onChanged(tuning.copyWith(
              velocityLookbackMs: _defaults.velocityLookbackMs)),
          canReset:
              tuning.velocityLookbackMs != _defaults.velocityLookbackMs,
        ),
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Gate lookback (ms) — '
              '${tuning.gateLookbackMs.toStringAsFixed(1)}',
          subtitle: 'Window for the velocity that drives the '
              'trigger ramp. Shorter = gate opens/closes with '
              'current speed instead of a long average.',
          value: tuning.gateLookbackMs,
          min: 4,
          max: 100,
          onChanged: (v) => onChanged(tuning.copyWith(gateLookbackMs: v)),
          onReset: () => onChanged(
              tuning.copyWith(gateLookbackMs: _defaults.gateLookbackMs)),
          canReset: tuning.gateLookbackMs != _defaults.gateLookbackMs,
        ),
        const SizedBox(height: 24),
        const _TuningGroupHeader('Path safeguards'),
        InspectorSlider(
          label: 'Max sample gap (ms) — '
              '${tuning.maxSampleGapMs.toStringAsFixed(0)}',
          subtitle: 'Drops the trail when consecutive recording '
              'samples in the window are more than this far apart.',
          value: tuning.maxSampleGapMs,
          min: 16,
          max: 200,
          onChanged: (v) =>
              onChanged(tuning.copyWith(maxSampleGapMs: v)),
          onReset: () => onChanged(
              tuning.copyWith(maxSampleGapMs: _defaults.maxSampleGapMs)),
          canReset: tuning.maxSampleGapMs != _defaults.maxSampleGapMs,
        ),
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Warp displacement (px) — '
              '${tuning.largePairDispPx.toStringAsFixed(0)}',
          subtitle: 'Per-pair displacement above which the post-idle '
              'warp check kicks in.',
          value: tuning.largePairDispPx,
          min: 30,
          max: 500,
          onChanged: (v) =>
              onChanged(tuning.copyWith(largePairDispPx: v)),
          onReset: () => onChanged(
              tuning.copyWith(largePairDispPx: _defaults.largePairDispPx)),
          canReset: tuning.largePairDispPx != _defaults.largePairDispPx,
        ),
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Warp post-idle gap (ms) — '
              '${tuning.postIdleThresholdMs.toStringAsFixed(0)}',
          subtitle: 'A "fast" pair preceded by an idle pair of at '
              'least this duration is treated as a system warp '
              '(focus change, app switch) instead of real motion.',
          value: tuning.postIdleThresholdMs,
          min: 16,
          max: 500,
          onChanged: (v) =>
              onChanged(tuning.copyWith(postIdleThresholdMs: v)),
          onReset: () => onChanged(tuning.copyWith(
              postIdleThresholdMs: _defaults.postIdleThresholdMs)),
          canReset:
              tuning.postIdleThresholdMs != _defaults.postIdleThresholdMs,
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: tuning == _defaults
                ? null
                : () => onChanged(_defaults),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reset all'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }
}

class _TuningGroupHeader extends StatelessWidget {
  const _TuningGroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
