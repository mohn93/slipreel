import 'package:flutter/material.dart';
import 'package:screen_recorder/effects/motion_blur_tuning.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_graph_painter.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Animation tab — screen / cursor animation styles + motion blur.
///
/// Screen and cursor styles write through to the playback render
/// pipeline. Motion blur drives directional cursor stamps + an
/// anisotropic Gaussian on the screen layer; both are speed-gated so
/// the slider only takes effect when something is actually moving.
class AnimationTab extends StatefulWidget {
  const AnimationTab({
    super.key,
    required this.screenConfig,
    required this.onScreenConfigChanged,
    required this.cursorConfig,
    required this.onCursorConfigChanged,
    required this.motionBlur,
    required this.onMotionBlurChanged,
    required this.motionBlurTuning,
    required this.onMotionBlurTuningChanged,
    required this.library,
  });

  final ScreenAnimationConfig screenConfig;
  final ValueChanged<ScreenAnimationConfig> onScreenConfigChanged;
  final CursorAnimationConfig cursorConfig;
  final ValueChanged<CursorAnimationConfig> onCursorConfigChanged;
  final double motionBlur;
  final ValueChanged<double> onMotionBlurChanged;
  final MotionBlurTuning motionBlurTuning;
  final ValueChanged<MotionBlurTuning> onMotionBlurTuningChanged;
  final CurveLibrary library;

  @override
  State<AnimationTab> createState() => _AnimationTabState();
}

class _AnimationTabState extends State<AnimationTab> {
  /// Default seed curve for the Screen Custom tile when the user picks
  /// it for the first time — matches CSS `ease-in-out` so the feel is
  /// close to the Smooth preset.
  static const _defaultScreenCustomCurve =
      CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0);

  /// Default seed curve for the Cursor Custom tile — CSS `ease`, which
  /// matches the Smooth cursor preset's feel.
  static const _defaultCursorCustomCurve =
      CubicBezierCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0);

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Right-side gutter keeps the curve editor's drag area clear of
      // the macOS Scrollbar's hit zone — without it, dragging a handle
      // near the right edge gets intercepted by the scrollbar.
      padding: const EdgeInsets.only(right: 12),
      children: [
        const Text(
          'Screen animation style',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in ScreenAnimationStyle.values)
              _AnimationOptionTile<ScreenAnimationStyle>(
                value: s,
                selected: widget.screenConfig.preset,
                label: s.label,
                icon: _screenIcon(s),
                previewCurve: s.previewCurve,
                previewDuration: s.previewDuration,
                onSelected: (s) => widget.onScreenConfigChanged(
                    ScreenAnimationConfig.preset(s)),
                size: 84,
              ),
            _CustomTile(
              selected: widget.screenConfig.isCustom,
              curve: widget.screenConfig.customCurve ??
                  _defaultScreenCustomCurve,
              onTap: () => widget.onScreenConfigChanged(
                ScreenAnimationConfig.custom(
                  curve: widget.screenConfig.customCurve ??
                      _defaultScreenCustomCurve,
                  badgeDuration: widget.screenConfig.badgeDuration,
                ),
              ),
              size: 84,
            ),
          ],
        ),
        if (widget.screenConfig.isCustom)
          CurveEditor(
            curve: widget.screenConfig.customCurve!,
            duration: widget.screenConfig.badgeDuration,
            durationLabel: 'Badge duration',
            durationMin: const Duration(milliseconds: 100),
            durationMax: const Duration(milliseconds: 1000),
            onCurveChanged: (c) => widget.onScreenConfigChanged(
              ScreenAnimationConfig.custom(
                curve: c,
                badgeDuration: widget.screenConfig.badgeDuration,
              ),
            ),
            onDurationChanged: (d) => widget.onScreenConfigChanged(
              ScreenAnimationConfig.custom(
                curve: widget.screenConfig.customCurve!,
                badgeDuration: d,
              ),
            ),
            library: widget.library,
            showDurationSlider: true,
          ),
        const SizedBox(height: 12),
        const InspectorSectionDivider(),
        const Text(
          'Cursor animation style',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in CursorAnimationStyle.values)
              _AnimationOptionTile<CursorAnimationStyle>(
                value: s,
                selected: widget.cursorConfig.preset,
                label: s.label,
                icon: _cursorIcon(s),
                previewCurve: s.previewCurve,
                previewDuration: s.previewDuration,
                onSelected: (s) => widget.onCursorConfigChanged(
                    CursorAnimationConfig.preset(s)),
                size: 76,
              ),
            _CustomTile(
              selected: widget.cursorConfig.isCustom,
              curve: widget.cursorConfig.customCurve ??
                  _defaultCursorCustomCurve,
              onTap: () => widget.onCursorConfigChanged(
                CursorAnimationConfig.custom(
                  curve: widget.cursorConfig.customCurve ??
                      _defaultCursorCustomCurve,
                  // The "None" preset reports a zero window; promote it
                  // to a sensible default so the editor's slider has a
                  // non-degenerate starting value when the user first
                  // chooses Custom from None.
                  window: widget.cursorConfig.window == Duration.zero
                      ? const Duration(milliseconds: 300)
                      : widget.cursorConfig.window,
                ),
              ),
              size: 76,
            ),
          ],
        ),
        if (widget.cursorConfig.isCustom)
          CurveEditor(
            curve: widget.cursorConfig.customCurve!,
            duration: widget.cursorConfig.window,
            durationLabel: 'Catch-up window',
            durationMin: const Duration(milliseconds: 50),
            durationMax: const Duration(milliseconds: 1500),
            onCurveChanged: (c) => widget.onCursorConfigChanged(
              CursorAnimationConfig.custom(
                curve: c,
                window: widget.cursorConfig.window,
              ),
            ),
            onDurationChanged: (d) => widget.onCursorConfigChanged(
              CursorAnimationConfig.custom(
                curve: widget.cursorConfig.customCurve!,
                window: d,
              ),
            ),
            library: widget.library,
            showDurationSlider: true,
          ),
        const SizedBox(height: 12),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Motion blur',
          subtitle:
              'While mouse cursor or screen is moving, cinematic motion '
              'blur effect will be applied.',
          value: widget.motionBlur,
          min: 0,
          max: 1,
          onChanged: widget.onMotionBlurChanged,
          onReset: () => widget.onMotionBlurChanged(0),
          canReset: widget.motionBlur != 0,
        ),
        const SizedBox(height: 24),
        InspectorCollapsible(
          title: 'Advanced motion blur settings',
          child: _MotionBlurTuningPanel(
            tuning: widget.motionBlurTuning,
            onChanged: widget.onMotionBlurTuningChanged,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static IconData _screenIcon(ScreenAnimationStyle s) =>
      switch (s) {
        ScreenAnimationStyle.focused => Icons.adjust,
        ScreenAnimationStyle.smooth => Icons.timeline,
      };

  static IconData _cursorIcon(CursorAnimationStyle s) => switch (s) {
        CursorAnimationStyle.smooth => Icons.touch_app_outlined,
        CursorAnimationStyle.medium => Icons.swipe,
        CursorAnimationStyle.rapid => Icons.bolt,
        CursorAnimationStyle.none => Icons.near_me,
      };
}

/// Live-tunable knobs for the cursor motion-blur path. Each slider
/// drives one field on [MotionBlurTuning]; changes call back to the
/// parent which feeds them to the painter on the next frame.
///
/// Defaults baked into [MotionBlurTuning] match the values previously
/// hardcoded as `static const` on `CursorOverlayPainter`. The "Reset"
/// button on each slider snaps that one knob back to its default;
/// "Reset all" at the bottom resets the whole panel.
class _MotionBlurTuningPanel extends StatelessWidget {
  const _MotionBlurTuningPanel({
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

/// Tile that defaults to icon + label, but on hover swaps the icon
/// for an animated horizontal track previewing the option's curve.
/// One [AnimationController] per tile, only ticking while hovered.
class _AnimationOptionTile<T> extends StatefulWidget {
  const _AnimationOptionTile({
    super.key,
    required this.value,
    required this.selected,
    required this.label,
    required this.icon,
    required this.previewCurve,
    required this.previewDuration,
    required this.onSelected,
    required this.size,
  });

  final T value;
  // Nullable: when the parent's config is in custom mode, no preset is
  // selected — rendered with `==` against null so all preset tiles
  // appear unselected, which is correct.
  final T? selected;
  final String label;
  final IconData icon;
  final Curve previewCurve;
  final Duration previewDuration;
  final ValueChanged<T> onSelected;
  final double size;

  @override
  State<_AnimationOptionTile<T>> createState() =>
      _AnimationOptionTileState<T>();
}

class _AnimationOptionTileState<T> extends State<_AnimationOptionTile<T>>
    with SingleTickerProviderStateMixin {
  // Created eagerly in initState rather than via a `late final` field
  // initializer — a lazy field would only construct on first access,
  // and if the tile was never hovered before its parent unmounts the
  // initializer would run inside dispose(), where creating a Ticker
  // (via SingleTickerProviderStateMixin) calls
  // getInheritedWidgetOfExactType on a deactivated element and throws
  // "Looking up a deactivated widget's ancestor is unsafe."
  late final AnimationController _ctrl;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: widget.previewDuration,
    );
  }

  @override
  void didUpdateWidget(_AnimationOptionTile<T> old) {
    super.didUpdateWidget(old);
    if (old.previewDuration != widget.previewDuration) {
      _ctrl.duration = widget.previewDuration;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onHover(bool hovered) {
    if (hovered == _hover) return;
    setState(() => _hover = hovered);
    if (hovered) {
      _ctrl.repeat(reverse: true);
    } else {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.value == widget.selected;
    return MouseRegion(
      onEnter: (_) => _onHover(true),
      onExit: (_) => _onHover(false),
      child: InkWell(
        onTap: () => widget.onSelected(widget.value),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: widget.size,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: widget.size,
                decoration: BoxDecoration(
                  color: kInspectorPanel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? kInspectorAccent
                        : kInspectorBorder,
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: _hover
                    ? _DemoTrack(
                        controller: _ctrl,
                        curve: widget.previewCurve,
                      )
                    : Icon(widget.icon,
                        color: Colors.white, size: 22),
              ),
              const SizedBox(height: 6),
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tile that opens the inline curve editor. Renders a tiny preview of
/// the user's current bezier as the tile's body so the tile reflects
/// the curve they're about to edit (or just edited).
class _CustomTile extends StatelessWidget {
  const _CustomTile({
    required this.selected,
    required this.curve,
    required this.onTap,
    required this.size,
  });

  final bool selected;
  final CubicBezierCurve curve;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: size,
              decoration: BoxDecoration(
                color: kInspectorPanel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? kInspectorAccent
                      : kInspectorBorder,
                  width: 1,
                ),
              ),
              child: CustomPaint(
                painter: CurveGraphPainter(
                  curve: curve,
                  demoProgress: 0.5,
                  draggingHandle: 0,
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Custom',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoTrack extends StatelessWidget {
  const _DemoTrack({required this.controller, required this.curve});
  final AnimationController controller;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = curve.transform(controller.value);
        return CustomPaint(
          painter: _DemoTrackPainter(progress: t),
          size: const Size(double.infinity, double.infinity),
        );
      },
    );
  }
}

class _DemoTrackPainter extends CustomPainter {
  _DemoTrackPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = 12.0;
    final y = size.height / 2;
    final left = Offset(inset, y);
    final right = Offset(size.width - inset, y);

    canvas.drawLine(
      left,
      right,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    final dotX = left.dx + (right.dx - left.dx) * progress.clamp(0.0, 1.0);
    canvas.drawCircle(
      Offset(dotX, y),
      6,
      Paint()..color = kInspectorAccent,
    );
    canvas.drawCircle(
      Offset(dotX, y),
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _DemoTrackPainter old) =>
      old.progress != progress;
}
