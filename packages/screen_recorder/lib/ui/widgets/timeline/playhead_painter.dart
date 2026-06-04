import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Paints the timeline playhead (knob + glowing vertical line) and the
/// hover-preview indicator (thin ring + line drawn behind the playhead).
///
/// Lives above the timeline lanes inside an [IgnorePointer] +
/// [AnimatedOpacity] in [EditorTimeline] so a trim drag can fade both
/// affordances out simultaneously without recomputing layout.
class PlayheadPainter extends CustomPainter {
  PlayheadPainter({
    required this.progress,
    required this.hoverProgress,
    required this.rulerHeight,
    this.flashOn = false,
  });

  final double progress;
  final double? hoverProgress;
  final double rulerHeight;
  /// When true, the line/knob gradient swaps to a solid accent fill
  /// signalling a rejected Cmd+K cut. The parent holds this true for
  /// 120ms before flipping it back; this painter just renders the
  /// current snapshot.
  final bool flashOn;

  static const Color _flashAccent = Color(0xFF6C63FF);

  static const _knobRadius = 6.5;
  static const _lineWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Hover preview indicator (drawn first, so the regular playhead
    // sits on top when both end up at the same x). Only present when
    // the cursor is hovering the timeline and playback is paused.
    if (hoverProgress != null) {
      final hx = size.width * hoverProgress!;
      final hoverPaint = Paint()
        ..color = const Color(0x99FFFFFF)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(hx, rulerHeight - 2),
        Offset(hx, size.height),
        hoverPaint,
      );
      // Small ring at the top so the ghost reads as an indicator,
      // not a stray line.
      canvas.drawCircle(
        Offset(hx, rulerHeight - 6),
        4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xCCFFFFFF),
      );
    }

    final x = size.width * progress;
    final knobCenter = Offset(x, _knobRadius);
    final lineTop = _knobRadius + _knobRadius - 1;
    final lineRect = Rect.fromLTWH(
      x - _lineWidth / 2,
      lineTop,
      _lineWidth,
      size.height - lineTop,
    );

    // ── Vertical line: blue → dark purple → transparent. The flash
    // path swaps the saturated colours for the accent so a rejected
    // Cmd+K reads as a deliberate signal, not a colour glitch.
    final lineGradient = flashOn
        ? const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _flashAccent,
              _flashAccent,
              _flashAccent,
              Color(0x006C63FF),
            ],
            stops: [0.0, 0.35, 0.7, 1.0],
          ).createShader(lineRect)
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              playheadTop,
              playheadMid,
              playheadBottom,
              Color(0x003D26AA),
            ],
            stops: [0.0, 0.35, 0.7, 1.0],
          ).createShader(lineRect);

    // Soft outer glow for the line.
    final glowPaint = Paint()
      ..shader = lineGradient
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..color = const Color(0xFF000000); // shader overrides; color carries alpha into mask
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        lineRect.inflate(0.5), const Radius.circular(2)),
      glowPaint,
    );

    // Solid line on top of the glow.
    canvas.drawRRect(
      RRect.fromRectAndRadius(lineRect, const Radius.circular(1.5)),
      Paint()..shader = lineGradient,
    );

    // ── Knob (button-like cap): drop shadow + outer glow + gradient fill +
    // inner highlight. Uses the same blue-to-purple palette but fully
    // opaque so it stays prominent.
    final knobRect = Rect.fromCircle(
      center: knobCenter,
      radius: _knobRadius,
    );
    final knobGradient = flashOn
        ? const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_flashAccent, _flashAccent],
          ).createShader(knobRect)
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [playheadTop, playheadBottom],
          ).createShader(knobRect);

    // Drop shadow underneath.
    canvas.drawCircle(
      knobCenter.translate(0, 1.5),
      _knobRadius,
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Soft outer cyan glow to tie the knob into the line.
    canvas.drawCircle(
      knobCenter,
      _knobRadius + 2,
      Paint()
        ..color = const Color(0x554FC3FF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Gradient fill.
    canvas.drawCircle(
      knobCenter,
      _knobRadius,
      Paint()..shader = knobGradient,
    );
    // Crisp 1px ring so the knob reads against light backgrounds too.
    canvas.drawCircle(
      knobCenter,
      _knobRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x88FFFFFF),
    );
    // Specular highlight.
    canvas.drawCircle(
      knobCenter.translate(0, -1.8),
      2.2,
      Paint()..color = const Color(0x88FFFFFF),
    );
  }

  @override
  bool shouldRepaint(PlayheadPainter old) =>
      old.progress != progress ||
      old.hoverProgress != hoverProgress ||
      old.rulerHeight != rulerHeight ||
      old.flashOn != flashOn;
}
