import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Cursor tab — size, style, behavior toggles, click-effect section.
///
/// Most controls remain local-state placeholders — the recorded cursor
/// track is rendered elsewhere and doesn't yet honor them. The "Hide
/// cursor" toggle is the exception: it's lifted to the playback screen
/// because suppressing the synthetic cursor overlay needs to happen
/// outside this widget's scope.
class CursorTab extends StatefulWidget {
  const CursorTab({
    super.key,
    required this.hideCursor,
    required this.canHideCursor,
    required this.onHideCursorChanged,
  });

  /// Current value of the synthetic cursor overlay's hidden state.
  final bool hideCursor;

  /// Whether the toggle is meaningful for the current recording.
  /// False for legacy recordings without a separate cursor track —
  /// their cursor is baked into the video and can't be hidden.
  final bool canHideCursor;

  /// Lifted setter for [hideCursor]. Ignored when [canHideCursor] is
  /// false (the toggle renders disabled).
  final ValueChanged<bool> onHideCursorChanged;

  @override
  State<CursorTab> createState() => _CursorTabState();
}

class _CursorTabState extends State<CursorTab> {
  double _size = 1.0;
  _CursorStyle _style = _CursorStyle.modernDark;
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
          value: _size,
          min: 0.5,
          max: 2.0,
          onChanged: (v) => setState(() => _size = v),
          onReset: () => setState(() => _size = 1.0),
          canReset: _size != 1.0,
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
        InspectorOptionRow<_CursorStyle>(
          items: _CursorStyle.values,
          selected: _style,
          onSelected: (s) => setState(() => _style = s),
          iconOf: (s) => s._buildPreview(),
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
        InspectorCollapsible(
          title: 'Click effect',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Visual feedback when the cursor clicks. Coming soon.',
                style: TextStyle(
                    color: Colors.white60,
                    fontSize: 13,
                    height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Built-in cursor style presets the picker shows. Previews are drawn
/// inline rather than from asset images so the tab works without
/// shipping cursor pixmaps.
enum _CursorStyle {
  classic,
  modernDark,
  dot,
  bold,
  outlined,
}

extension on _CursorStyle {
  Widget _buildPreview() {
    switch (this) {
      case _CursorStyle.classic:
        return const _ArrowGlyph(
            fillColor: Colors.transparent, outlineColor: Colors.white);
      case _CursorStyle.modernDark:
        return const _ArrowGlyph(
            fillColor: Colors.white, outlineColor: Colors.black);
      case _CursorStyle.dot:
        return Container(
          width: 18,
          height: 18,
          decoration: const BoxDecoration(
            color: Colors.white60,
            shape: BoxShape.circle,
          ),
        );
      case _CursorStyle.bold:
        return const _ArrowGlyph(
            fillColor: Colors.white,
            outlineColor: Colors.white,
            strokeWidth: 0);
      case _CursorStyle.outlined:
        return const _ArrowGlyph(
            fillColor: Colors.white,
            outlineColor: Colors.white,
            strokeWidth: 1.6);
    }
  }
}

/// Inline arrow-cursor glyph drawn with a CustomPainter so we don't
/// rely on assets. Mirrors the shape of the macOS arrow pointer.
class _ArrowGlyph extends StatelessWidget {
  const _ArrowGlyph({
    required this.fillColor,
    required this.outlineColor,
    this.strokeWidth = 1.4,
  });

  final Color fillColor;
  final Color outlineColor;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(20, 24),
      painter: _ArrowPainter(
        fillColor: fillColor,
        outlineColor: outlineColor,
        strokeWidth: strokeWidth,
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({
    required this.fillColor,
    required this.outlineColor,
    required this.strokeWidth,
  });

  final Color fillColor;
  final Color outlineColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.15, h * 0.05)
      ..lineTo(w * 0.85, h * 0.55)
      ..lineTo(w * 0.55, h * 0.6)
      ..lineTo(w * 0.7, h * 0.92)
      ..lineTo(w * 0.55, h * 0.96)
      ..lineTo(w * 0.4, h * 0.66)
      ..lineTo(w * 0.15, h * 0.85)
      ..close();
    if (fillColor != Colors.transparent) {
      canvas.drawPath(path, Paint()..color = fillColor);
    }
    if (strokeWidth > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = outlineColor
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) =>
      old.fillColor != fillColor ||
      old.outlineColor != outlineColor ||
      old.strokeWidth != strokeWidth;
}
