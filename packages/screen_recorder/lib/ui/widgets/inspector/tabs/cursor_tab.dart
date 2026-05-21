import 'package:flutter/material.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/rendering/spring_config.dart';
import 'package:screen_recorder/state/cursor_post_process.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Cursor tab — size, style, behavior toggles, click-effect section.
///
/// Size, style, and "Hide cursor" are wired to the playback overlay
/// and the export pipeline. The remaining toggles (always-pointer,
/// hide-if-still, loop-position, click-effect) are still local-state
/// placeholders.
class CursorTab extends StatefulWidget {
  const CursorTab({
    super.key,
    required this.size,
    required this.onSizeChanged,
    required this.style,
    required this.onStyleChanged,
    required this.clickEffect,
    required this.onClickEffectChanged,
    required this.hideCursor,
    required this.canHideCursor,
    required this.onHideCursorChanged,
    required this.shadow,
    required this.onShadowChanged,
    required this.motionSpring,
    required this.onMotionSpringChanged,
    required this.clickSpring,
    required this.onClickSpringChanged,
    required this.cursorDelay,
    required this.onCursorDelayChanged,
    required this.postProcess,
    required this.onPostProcessChanged,
  });

  final double size;
  final ValueChanged<double> onSizeChanged;
  final CursorStyle style;
  final ValueChanged<CursorStyle> onStyleChanged;
  final CursorClickEffect clickEffect;
  final ValueChanged<CursorClickEffect> onClickEffectChanged;
  final bool hideCursor;
  final bool canHideCursor;
  final ValueChanged<bool> onHideCursorChanged;
  final double shadow;
  final ValueChanged<double> onShadowChanged;

  /// Spring driving the cursor's motion chase. The two sliders edit
  /// this in place; switching the Animation tab's cursor preset
  /// rewrites it (the preset picker remains the broad-feel choice,
  /// these sliders are fine-tune knobs over the same parameter).
  final MotionSpring motionSpring;
  final ValueChanged<MotionSpring> onMotionSpringChanged;

  /// Spring driving the press-pulse size animation on click + release.
  final ClickSpring clickSpring;
  final ValueChanged<ClickSpring> onClickSpringChanged;

  /// Debug — how far back in time to sample the cursor recording when
  /// rendering, so the sprite visually lines up with an app's UI
  /// redraw delay (the recording shows UI responding ~16–200 ms after
  /// the cursor event; tune until the sprite reaches the button at
  /// the same moment the highlight appears).
  final Duration cursorDelay;
  final ValueChanged<Duration> onCursorDelayChanged;

  /// Bundle of advanced per-project cursor filters (end-freeze, despike,
  /// state-debounce). Lives in the Advanced section at the bottom of
  /// the tab. Updating one field rebuilds the whole bundle via
  /// [CursorPostProcess.copyWith].
  final CursorPostProcess postProcess;
  final ValueChanged<CursorPostProcess> onPostProcessChanged;

  @override
  State<CursorTab> createState() => _CursorTabState();
}

class _CursorTabState extends State<CursorTab> {
  bool _alwaysPointer = false;
  bool _hideIfStill = false;
  bool _loopPosition = false;
  bool _advancedExpanded = true;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        InspectorSlider(
          label: 'Cursor size',
          value: widget.size,
          min: 0.5,
          max: 8.0,
          onChanged: widget.onSizeChanged,
          onReset: () => widget.onSizeChanged(2.0),
          canReset: widget.size != 2.0,
          subtitle: '${widget.size.toStringAsFixed(2)}×',
        ),
        const SizedBox(height: 20),
        InspectorSlider(
          label: 'Cursor shadow',
          subtitle: widget.shadow > 0
              ? '${(widget.shadow * 100).round()}%'
              : 'Off',
          value: widget.shadow,
          min: 0,
          max: 1,
          onChanged: widget.onShadowChanged,
          onReset: () => widget.onShadowChanged(0.4),
          canReset: widget.shadow != 0.4,
        ),
        const InspectorSectionDivider(),
        const Text(
          'Cursor style',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        InspectorOptionRow<CursorStyle>(
          items: CursorStyle.values,
          selected: widget.style,
          onSelected: widget.onStyleChanged,
          iconOf: (s) => _CursorStylePreview(style: s),
          labelOf: (_) => null,
        ),
        const InspectorSectionDivider(),
        InspectorToggle(
          label: 'Always use pointer cursor',
          subtitle: "Don't change cursor, even if selecting text, etc.",
          value: _alwaysPointer,
          onChanged: (v) => setState(() => _alwaysPointer = v),
        ),
        const InspectorSectionDivider(),
        InspectorToggle(
          label: 'Hide cursor if not moving',
          value: _hideIfStill,
          onChanged: (v) => setState(() => _hideIfStill = v),
        ),
        const SizedBox(height: 20),
        InspectorToggle(
          label: 'Loop cursor position',
          subtitle:
              'Near the end of the video, cursor will move back to its '
              'initial position',
          value: _loopPosition,
          onChanged: (v) => setState(() => _loopPosition = v),
        ),
        const SizedBox(height: 20),
        InspectorToggle(
          label: 'Hide cursor',
          leadingIcon: Icons.visibility_off_outlined,
          subtitle: widget.canHideCursor
              ? null
              : 'Available for recordings made with this version.',
          value: widget.canHideCursor && widget.hideCursor,
          onChanged:
              widget.canHideCursor ? widget.onHideCursorChanged : null,
        ),
        const InspectorSectionDivider(),
        const Text(
          'Click effect',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'A press animation always plays on click. Pick what '
          'else happens.',
          style: TextStyle(
            color: kInspectorMuted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        InspectorOptionRow<CursorClickEffect>(
          items: CursorClickEffect.values,
          selected: widget.clickEffect,
          onSelected: widget.onClickEffectChanged,
          iconOf: (e) => _ClickEffectPreview(effect: e),
          labelOf: (e) => e.label,
        ),
        const InspectorSectionDivider(),
        const Text(
          'Springs',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Stiffness controls how fast each animation chases its target. '
          'Damping below 1.0 adds bounce; 1.0 settles cleanly.',
          style: TextStyle(
            color: kInspectorMuted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        ..._motionSpringSliders(),
        const SizedBox(height: 16),
        ..._clickSpringSliders(),
        const InspectorSectionDivider(),
        const Text(
          'Debug',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Experimental controls. Off by default.',
          style: TextStyle(
            color: kInspectorMuted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Cursor delay',
          subtitle: () {
            final ms = widget.cursorDelay.inMilliseconds;
            if (ms == 0) return 'Off';
            if (ms > 0) return '$ms ms (lag)';
            return '${-ms} ms (lead)';
          }(),
          // Range goes negative so the cursor can be advanced past the
          // spring's intrinsic 75-ms lag (useful for apps that
          // *immediately* respond to cursor events with no animation —
          // there the sprite should *lead* the recorded UI by a few
          // frames to look right). 0 = no shift, +N ms = sprite lags
          // by N ms, −N ms = sprite leads by N ms.
          value: widget.cursorDelay.inMicroseconds / 1000.0,
          min: -100,
          max: 500,
          onChanged: (v) => widget.onCursorDelayChanged(
              Duration(microseconds: (v * 1000).round())),
          onReset: () => widget.onCursorDelayChanged(Duration.zero),
          canReset: widget.cursorDelay != Duration.zero,
        ),
        const InspectorSectionDivider(),
        ..._advancedSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  /// "Advanced" section — collapsible group of per-project cursor
  /// filters (end-of-clip freeze, shake removal, rapid-state-change
  /// debounce). Mirrors ScreenStudio's section of the same name.
  /// State for each control flows through [CursorPostProcess.copyWith]
  /// so a single onChange handler keeps the bundle consistent.
  List<Widget> _advancedSection() {
    final pp = widget.postProcess;
    return [
      InkWell(
        onTap: () => setState(() => _advancedExpanded = !_advancedExpanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Advanced',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(
                _advancedExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                color: Colors.white70,
                size: 20,
              ),
            ],
          ),
        ),
      ),
      if (_advancedExpanded) ...[
        const SizedBox(height: 16),
        InspectorSlider(
          label: 'Stop cursor movement at the end of the video',
          subtitle: 'Near the end of the video, the last mouse movement '
              'often leads to clicking "Stop Recording," which you might '
              'not want to be visible. Adjust how long before the end of '
              'the video the mouse cursor will stop moving.\n'
              '${pp.endFreezeMs == 0 ? 'Off' : '${pp.endFreezeMs} ms'}',
          value: pp.endFreezeMs.toDouble(),
          min: 0,
          max: CursorPostProcess.endFreezeMaxMs.toDouble(),
          onChanged: (v) => widget.onPostProcessChanged(
            pp.copyWith(endFreezeMs: v.round()),
          ),
          onReset: () => widget.onPostProcessChanged(
            pp.copyWith(endFreezeMs: 0),
          ),
          canReset: pp.endFreezeMs != 0,
        ),
        const SizedBox(height: 20),
        InspectorToggle(
          label: 'Remove cursor shakes',
          subtitle: 'If you use some accessibility apps that can control '
              'your mouse, it is possible those apps will cause sudden, '
              'short movements of your mouse. This option allows trying '
              'to detect and remove them.',
          value: pp.removeShakes,
          onChanged: (v) => widget.onPostProcessChanged(
            pp.copyWith(removeShakes: v),
          ),
        ),
        const SizedBox(height: 20),
        InspectorSlider(
          label: 'Remove cursor shakes threshold',
          subtitle: '${pp.shakeThresholdPx.toStringAsFixed(0)} px',
          value: pp.shakeThresholdPx,
          min: 5,
          max: 60,
          onChanged: (v) => widget.onPostProcessChanged(
            pp.copyWith(shakeThresholdPx: v),
          ),
          onReset: () => widget.onPostProcessChanged(
            pp.copyWith(
              shakeThresholdPx: CursorPostProcess.defaultShakeThresholdPx,
            ),
          ),
          canReset: pp.shakeThresholdPx !=
              CursorPostProcess.defaultShakeThresholdPx,
        ),
        const SizedBox(height: 20),
        InspectorToggle(
          label: 'Optimize cursor changes',
          subtitle: 'Slipreel will try to minimize rapid cursor changes '
              '(eg when quickly moving over some elements) when this '
              'option is enabled.',
          value: pp.optimizeChanges,
          onChanged: (v) => widget.onPostProcessChanged(
            pp.copyWith(optimizeChanges: v),
          ),
        ),
      ],
    ];
  }

  // The motion spring is logically owned by the Animation tab's
  // cursor preset, but the fine-tune knobs live here. When isSnap
  // (None preset) the sliders fall back to the smooth defaults so
  // they're touchable; the first drag converts the active config to
  // a custom spring (the parent does that conversion in its
  // onMotionSpringChanged handler).
  List<Widget> _motionSpringSliders() {
    final s = widget.motionSpring;
    final stiffness = s.isSnap ? 180.0 : s.stiffness;
    final damping = s.isSnap ? 1.0 : s.damping;
    return [
      InspectorSlider(
        label: 'Motion stiffness',
        subtitle: stiffness.round().toString(),
        value: stiffness,
        min: 50,
        max: 1500,
        onChanged: (v) =>
            widget.onMotionSpringChanged(s.copyWith(stiffness: v)),
        onReset: () =>
            widget.onMotionSpringChanged(s.copyWith(stiffness: 180)),
        canReset: stiffness != 180,
      ),
      const SizedBox(height: 20),
      InspectorSlider(
        label: 'Motion damping',
        subtitle: damping.toStringAsFixed(2),
        value: damping,
        min: 0.3,
        max: 1.4,
        onChanged: (v) =>
            widget.onMotionSpringChanged(s.copyWith(damping: v)),
        onReset: () =>
            widget.onMotionSpringChanged(s.copyWith(damping: 1.0)),
        canReset: damping != 1.0,
      ),
    ];
  }

  List<Widget> _clickSpringSliders() {
    final s = widget.clickSpring;
    return [
      InspectorSlider(
        label: 'Click stiffness',
        subtitle: s.stiffness.round().toString(),
        value: s.stiffness,
        min: 100,
        max: 1200,
        onChanged: (v) =>
            widget.onClickSpringChanged(s.copyWith(stiffness: v)),
        onReset: () =>
            widget.onClickSpringChanged(s.copyWith(stiffness: 350)),
        canReset: s.stiffness != 350,
      ),
      const SizedBox(height: 20),
      InspectorSlider(
        label: 'Click damping',
        subtitle: s.damping.toStringAsFixed(2),
        value: s.damping,
        min: 0.3,
        max: 1.4,
        onChanged: (v) =>
            widget.onClickSpringChanged(s.copyWith(damping: v)),
        onReset: () =>
            widget.onClickSpringChanged(s.copyWith(damping: 1.0)),
        canReset: s.damping != 1.0,
      ),
    ];
  }
}

/// Tile-sized preview for the click-effect picker. Shows the cursor
/// glyph with a static halo for [CursorClickEffect.ripple] and just
/// the cursor for [CursorClickEffect.none].
class _ClickEffectPreview extends StatelessWidget {
  const _ClickEffectPreview({required this.effect});
  final CursorClickEffect effect;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(36, 36),
      painter: _ClickEffectPreviewPainter(effect: effect),
    );
  }
}

class _ClickEffectPreviewPainter extends CustomPainter {
  _ClickEffectPreviewPainter({required this.effect});
  final CursorClickEffect effect;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    if (effect == CursorClickEffect.ripple) {
      // Frozen mid-ripple ring so the tile reads as "with halo".
      canvas.drawCircle(
        center,
        size.shortestSide * 0.42,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white.withValues(alpha: 0.45)
          ..strokeWidth = 2,
      );
    }
    // Anchor the arrow's tip near the center so the ring (when present)
    // halos the tip the way it does in playback.
    paintCursorGlyph(
      canvas,
      position: center,
      diameter: size.shortestSide * 0.55,
      style: CursorStyle.modernDark,
    );
  }

  @override
  bool shouldRepaint(covariant _ClickEffectPreviewPainter old) =>
      old.effect != effect;
}

/// Tile-sized preview of a cursor style. Renders via the shared
/// [paintCursorGlyph] helper so the picker tile, the playback overlay,
/// and the exported video all match exactly.
class _CursorStylePreview extends StatelessWidget {
  const _CursorStylePreview({required this.style});
  final CursorStyle style;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(20, 24),
      painter: _CursorStylePreviewPainter(style: style),
    );
  }
}

class _CursorStylePreviewPainter extends CustomPainter {
  _CursorStylePreviewPainter({required this.style});
  final CursorStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final isDot = style == CursorStyle.dot;
    // Dot is centered. Arrows: tip is anchored slightly inside the
    // upper-left of the tile so the white halo (which extends ~17%
    // of the body height up-left from the tip and ~73% down-right
    // along the diagonal) fits inside the tile.
    final position = isDot
        ? Offset(size.width / 2, size.height / 2)
        : Offset(size.width * 0.15, size.height * 0.15);
    final diameter = isDot
        ? size.shortestSide * 0.75
        : size.height * 0.75;
    paintCursorGlyph(
      canvas,
      position: position,
      diameter: diameter,
      style: style,
    );
  }

  @override
  bool shouldRepaint(covariant _CursorStylePreviewPainter old) =>
      old.style != style;
}
