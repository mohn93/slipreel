import 'package:flutter/material.dart';

/// Draws a 60% black backdrop with a rounded-rect cutout around
/// [anchorRect] and a callout bubble pointing at the cutout.
class TipOverlay extends StatelessWidget {
  const TipOverlay({
    super.key,
    required this.anchorRect,
    required this.message,
    required this.onDismiss,
  });

  final Rect anchorRect;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Backdrop with cutout.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _BackdropPainter(anchorRect)),
          ),
        ),
        // Tap outside the bubble dismisses.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        // Callout positioned below the anchor (or above if no room below).
        _Callout(
          anchorRect: anchorRect,
          message: message,
          onDismiss: onDismiss,
        ),
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.anchorRect);
  final Rect anchorRect;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = const Color(0x99000000);
    final cutoutRRect =
        RRect.fromRectAndRadius(anchorRect.inflate(6), const Radius.circular(10));
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(cutoutRRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.anchorRect != anchorRect;
}

class _Callout extends StatelessWidget {
  const _Callout({
    required this.anchorRect,
    required this.message,
    required this.onDismiss,
  });
  final Rect anchorRect;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context).size;
    final spaceBelow = mq.height - anchorRect.bottom;
    final placeBelow = spaceBelow >= 140;
    final dy = placeBelow ? anchorRect.bottom + 16 : anchorRect.top - 140;

    return Positioned(
      top: dy.clamp(16.0, mq.height - 160),
      left: 16,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: onDismiss,
                  child: const Text('Got it'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
