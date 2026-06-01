import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Draws a 60% black backdrop with a rounded-rect cutout around
/// [anchorRect] and a callout bubble pointing at the cutout.
class TipOverlay extends StatelessWidget {
  const TipOverlay({
    super.key,
    required this.anchorRect,
    required this.message,
    required this.onDismiss,
    this.dimBackdrop = true,
  });

  final Rect anchorRect;
  final String message;
  final VoidCallback onDismiss;
  // When false, no dim/cutout backdrop is drawn and the callout sits strictly
  // below the anchor's host bottom edge. Used by the recording-bar tip where
  // the host window grows downward to host the bubble.
  final bool dimBackdrop;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (dimBackdrop)
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
          forceBelow: !dimBackdrop,
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
    this.forceBelow = false,
  });
  final Rect anchorRect;
  final String message;
  final VoidCallback onDismiss;
  // When true, the bubble is placed strictly below the anchor with a fixed
  // gap — no clamp, no above-anchor fallback. The host window is sized to
  // accommodate it (recording-bar tip).
  final bool forceBelow;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context).size;
    final scheme = Theme.of(context).colorScheme;
    if (forceBelow) {
      // Compact, free-floating chip below the anchor's host. Lighter than the
      // bar's surfaceContainerHigh, with its own border + heavier shadow so it
      // reads as a separate element instead of fusing with the bar chrome.
      return Positioned(
        top: anchorRect.bottom + 24,
        left: 0,
        right: 0,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            // No shadow — Flutter's blur rasterises with hard banding/outlines
            // against the borderless transparent NSWindow. Rely on the lighter
            // surfaceContainerHighest + outline border + dark window gap for
            // visual separation from the bar instead.
            child: Material(
              type: MaterialType.card,
              elevation: 0,
              borderRadius: BorderRadius.circular(14),
              color: scheme.surfaceContainerHighest,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      message,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface,
                            height: 1.35,
                          ),
                    ),
                    const SizedBox(height: 10),
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
          ),
        ),
      );
    }

    // Default (editor) placement: full-width with clamped top.
    final spaceBelow = mq.height - anchorRect.bottom;
    final placeBelow = spaceBelow >= 140;
    final dy = placeBelow ? anchorRect.bottom + 16 : anchorRect.top - 140;
    final maxTop = math.max(16.0, mq.height - 160);
    final top = dy.clamp(16.0, maxTop);
    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: scheme.surfaceContainerHigh,
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
