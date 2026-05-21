import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Cursor tab — size, style, behavior toggles, click-effect section.
///
/// Reads + writes the editor's cursor settings directly via the
/// [editorProjectControllerProvider]. `canHideCursor` stays as a
/// constructor prop because it depends on the cursor recording (a
/// session input, not editor state). Local toggles for not-yet-wired
/// settings (always-pointer, hide-if-still, loop-position) live on
/// the state object until they get real model fields.
class CursorTab extends ConsumerStatefulWidget {
  const CursorTab({super.key, required this.canHideCursor});

  /// Whether hiding the cursor is supported for the current recording.
  /// When false the "Hide cursor" toggle is rendered disabled.
  final bool canHideCursor;

  @override
  ConsumerState<CursorTab> createState() => _CursorTabState();
}

class _CursorTabState extends ConsumerState<CursorTab> {
  bool _alwaysPointer = false;
  bool _hideIfStill = false;
  bool _loopPosition = false;
  bool _advancedExpanded = true;

  EditorProjectController get _notifier =>
      ref.read(editorProjectControllerProvider.notifier);

  /// Re-wrap motion-spring slider changes into a custom-spring config.
  /// The Animation tab's preset picker keeps owning the broad-feel
  /// choice; these sliders are an override on top of it.
  void _setMotionSpring(MotionSpring s) {
    _notifier.setCursorAnimationConfig(
      CursorAnimationConfig.customSpring(spring: s),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ref.watch on the whole state — every slider drag rebuilds this
    // tab, matching the previous setState-driven scope. Granular
    // .select() per field would skip rebuilds when an unrelated field
    // changes; today there's no neighbour to optimise against because
    // each tab is rebuilt by its parent on selection switches anyway.
    final project = ref.watch(editorProjectControllerProvider);
    final size = project.cursorSize;
    final shadow = project.cursorShadow;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        InspectorSlider(
          label: 'Cursor size',
          value: size,
          min: 0.5,
          max: 8.0,
          onChanged: _notifier.setCursorSize,
          onReset: () => _notifier.setCursorSize(2.0),
          canReset: size != 2.0,
          subtitle: '${size.toStringAsFixed(2)}×',
        ),
        const SizedBox(height: 20),
        InspectorSlider(
          label: 'Cursor shadow',
          subtitle: shadow > 0 ? '${(shadow * 100).round()}%' : 'Off',
          value: shadow,
          min: 0,
          max: 1,
          onChanged: _notifier.setCursorShadow,
          onReset: () => _notifier.setCursorShadow(0.4),
          canReset: shadow != 0.4,
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
          selected: project.cursorStyle,
          onSelected: _notifier.setCursorStyle,
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
          value: widget.canHideCursor && project.hideCursorOverlay,
          onChanged: widget.canHideCursor
              ? _notifier.setHideCursorOverlay
              : null,
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
          selected: project.cursorClickEffect,
          onSelected: _notifier.setCursorClickEffect,
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
        ..._motionSpringSliders(project.cursorAnimationConfig.motionSpring),
        const SizedBox(height: 16),
        ..._clickSpringSliders(project.clickSpring),
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
        _MotionPresetPicker(
          active: ref.watch(motionTuningProvider.notifier).activePreset,
          onPick: (preset) {
            ref.read(motionTuningProvider.notifier).usePreset(preset);
            // Persist so next launch picks up this choice. Fire-and-
            // forget — store handles errors internally (logs only).
            ref
                .read(motionTuningStoreProvider)
                .save(preset.tuning);
          },
        ),
        const SizedBox(height: 20),
        InspectorSlider(
          label: 'Cursor delay',
          subtitle: () {
            final ms = project.cursorDelay.inMilliseconds;
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
          value: project.cursorDelay.inMicroseconds / 1000.0,
          min: -100,
          max: 500,
          onChanged: (v) => _notifier.setCursorDelay(
              Duration(microseconds: (v * 1000).round())),
          onReset: () => _notifier.setCursorDelay(Duration.zero),
          canReset: project.cursorDelay != Duration.zero,
        ),
        const InspectorSectionDivider(),
        ..._advancedSection(project.cursorPostProcess),
        const SizedBox(height: 24),
      ],
    );
  }

  /// "Advanced" section — collapsible group of per-project cursor
  /// filters (end-of-clip freeze, shake removal, rapid-state-change
  /// debounce). Mirrors ScreenStudio's section of the same name.
  /// State for each control flows through [CursorPostProcess.copyWith]
  /// so a single onChange handler keeps the bundle consistent.
  List<Widget> _advancedSection(CursorPostProcess pp) {
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
          onChanged: (v) => _notifier.setCursorPostProcess(
            pp.copyWith(endFreezeMs: v.round()),
          ),
          onReset: () => _notifier.setCursorPostProcess(
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
          onChanged: (v) => _notifier
              .setCursorPostProcess(pp.copyWith(removeShakes: v)),
        ),
        const SizedBox(height: 20),
        InspectorSlider(
          label: 'Remove cursor shakes threshold',
          subtitle: '${pp.shakeThresholdPx.toStringAsFixed(0)} px',
          value: pp.shakeThresholdPx,
          min: 5,
          max: 60,
          onChanged: (v) => _notifier.setCursorPostProcess(
            pp.copyWith(shakeThresholdPx: v),
          ),
          onReset: () => _notifier.setCursorPostProcess(
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
          onChanged: (v) => _notifier
              .setCursorPostProcess(pp.copyWith(optimizeChanges: v)),
        ),
      ],
    ];
  }

  // The motion spring is logically owned by the Animation tab's
  // cursor preset, but the fine-tune knobs live here. When isSnap
  // (None preset) the sliders fall back to the smooth defaults so
  // they're touchable; the first drag converts the active config to
  // a custom spring (see [_setMotionSpring]).
  List<Widget> _motionSpringSliders(MotionSpring s) {
    final stiffness = s.isSnap ? 180.0 : s.stiffness;
    final damping = s.isSnap ? 1.0 : s.damping;
    return [
      InspectorSlider(
        label: 'Motion stiffness',
        subtitle: stiffness.round().toString(),
        value: stiffness,
        min: 50,
        max: 1500,
        onChanged: (v) => _setMotionSpring(s.copyWith(stiffness: v)),
        onReset: () => _setMotionSpring(s.copyWith(stiffness: 180)),
        canReset: stiffness != 180,
      ),
      const SizedBox(height: 20),
      InspectorSlider(
        label: 'Motion damping',
        subtitle: damping.toStringAsFixed(2),
        value: damping,
        min: 0.3,
        max: 1.4,
        onChanged: (v) => _setMotionSpring(s.copyWith(damping: v)),
        onReset: () => _setMotionSpring(s.copyWith(damping: 1.0)),
        canReset: damping != 1.0,
      ),
    ];
  }

  List<Widget> _clickSpringSliders(ClickSpring s) {
    return [
      InspectorSlider(
        label: 'Click stiffness',
        subtitle: s.stiffness.round().toString(),
        value: s.stiffness,
        min: 100,
        max: 1200,
        onChanged: (v) => _notifier.setClickSpring(s.copyWith(stiffness: v)),
        onReset: () =>
            _notifier.setClickSpring(s.copyWith(stiffness: 350)),
        canReset: s.stiffness != 350,
      ),
      const SizedBox(height: 20),
      InspectorSlider(
        label: 'Click damping',
        subtitle: s.damping.toStringAsFixed(2),
        value: s.damping,
        min: 0.3,
        max: 1.4,
        onChanged: (v) => _notifier.setClickSpring(s.copyWith(damping: v)),
        onReset: () => _notifier.setClickSpring(s.copyWith(damping: 1.0)),
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

/// Compact preset picker for [MotionTuning]. Shown in the cursor
/// tab's Debug section so designers can A/B presets without
/// recompiling — pairs with the sidecar JSON load at startup. The
/// "Custom" row appears only when [active] is null (the current
/// tuning doesn't match any named preset — e.g. user-edited JSON).
class _MotionPresetPicker extends StatelessWidget {
  const _MotionPresetPicker({required this.active, required this.onPick});

  final MotionTuningPreset? active;
  final ValueChanged<MotionTuningPreset> onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Motion preset',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          active == null
              ? 'Custom (loaded from motion_tuning.json — pick a preset to '
                  'override).'
              : 'Active: ${active!.label}. Affects spring + scene-blur '
                  'tuning across preview and export.',
          style: const TextStyle(
            color: kInspectorMuted,
            fontSize: 11,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in MotionTuningPreset.values)
              _PresetChip(
                label: p.label,
                isSelected: active == p,
                onTap: () => onPick(p),
              ),
          ],
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? kInspectorAccent.withValues(alpha: 0.15)
              : kInspectorPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? kInspectorAccent.withValues(alpha: 0.5)
                : kInspectorBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? kInspectorAccent : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
