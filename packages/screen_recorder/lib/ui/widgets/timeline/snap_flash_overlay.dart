import 'package:flutter/material.dart';

/// Brief vertical glow at the edited-time x of a snap target. The
/// owning screen is responsible for clearing [target] after the fade
/// completes (240ms).
class SnapFlashOverlay extends StatelessWidget {
  const SnapFlashOverlay({
    super.key,
    required this.target,
    required this.editedTimeToPx,
  });

  /// The edited-time of the snap target. Null = render nothing.
  final Duration? target;

  /// Maps an edited-time to the x-pixel inside this widget's local
  /// coordinate space. Caller threads in the same mapper used for the
  /// playhead so the glow lines up exactly.
  final double Function(Duration) editedTimeToPx;

  @override
  Widget build(BuildContext context) {
    final t = target;
    if (t == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SnapFlashPainter(
          x: editedTimeToPx(t),
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _SnapFlashPainter extends CustomPainter {
  _SnapFlashPainter({required this.x, required this.color});

  final double x;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (x.isNaN || x.isInfinite) return;
    // Vertical glow: a 4px-wide rect centered on `x`, drawn at 60%
    // alpha with a soft blur mask so the edges feather. Shown for
    // ~240ms then cleared by the owning screen (no built-in fade —
    // the appearance is on/off).
    final rect = Rect.fromLTWH(x - 2, 0, 4, size.height);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _SnapFlashPainter oldDelegate) =>
      oldDelegate.x != x || oldDelegate.color != color;
}
