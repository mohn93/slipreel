import 'package:flutter/material.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
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

  @override
  State<CursorTab> createState() => _CursorTabState();
}

class _CursorTabState extends State<CursorTab> {
  bool _alwaysPointer = false;
  bool _hideIfStill = false;
  bool _loopPosition = false;

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
          onReset: () => widget.onSizeChanged(1.0),
          canReset: widget.size != 1.0,
          subtitle: '${widget.size.toStringAsFixed(2)}×',
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
        const SizedBox(height: 24),
      ],
    );
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
    // Dot is centered. Arrows: tip in the upper-left corner of the
    // tile, with diameter sized so the full bounding box (h≈18 units,
    // w≈12 units in the macOS-shape grid) fits inside the tile with
    // a hair of margin.
    final position = isDot
        ? Offset(size.width / 2, size.height / 2)
        : Offset(size.width * 0.1, size.height * 0.02);
    final diameter = isDot
        ? size.shortestSide * 0.75
        : size.height * 0.92;
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
