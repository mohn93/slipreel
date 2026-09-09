import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/theme/app_palette_context.dart';

/// Shown only after a verified entitlement grants exports on this Mac.
class ActivationSuccessDialog extends StatelessWidget {
  const ActivationSuccessDialog({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Dialog(
      backgroundColor: palette.surfaceCard,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: palette.dividerStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: reducedMotion ? 1 : 0, end: 1),
                  duration: reducedMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 850),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => CustomPaint(
                    size: const Size(220, 132),
                    painter: _ActivationArtwork(
                      progress: value,
                      accent: palette.accent,
                      surface: palette.surfaceElevated,
                      line: palette.dividerStrong,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'You’re all set.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Unlimited exports unlocked',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  autofocus: true,
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: const Color(0xFF100C29),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text(
                    'Let’s create',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                  foregroundColor: palette.textSecondary,
                ),
                child: const Text('Manage account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A recording frame resolves into a checkmark, with one short celebratory burst.
class _ActivationArtwork extends CustomPainter {
  const _ActivationArtwork({
    required this.progress,
    required this.accent,
    required this.surface,
    required this.line,
  });

  final double progress;
  final Color accent;
  final Color surface;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, 62);
    final paint = Paint();
    canvas.drawCircle(center, 58, paint..color = accent.withValues(alpha: .07));
    final frame = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: 116, height: 78),
      const Radius.circular(14),
    );
    canvas.drawRRect(frame, paint..color = surface);
    canvas.drawRRect(
      frame,
      paint
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(
      center + const Offset(-43, -26),
      3,
      paint..color = accent,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(center.dx - 34, center.dy + 48, 68, 5),
        const Radius.circular(3),
      ),
      paint..color = accent.withValues(alpha: .35),
    );
    canvas.drawCircle(
      center,
      25 * (.75 + .25 * progress),
      paint..color = accent,
    );
    final check = Path()
      ..moveTo(center.dx - 10, center.dy)
      ..lineTo(center.dx - 3, center.dy + 7)
      ..lineTo(center.dx + 11, center.dy - 8);
    final metric = check.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      paint
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    // Resting flecks stay subtle; no looping motion while the user reads.
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4 + .18;
      final radius = 53 + 24 * progress;
      final point =
          center +
          Offset(math.cos(angle) * radius, math.sin(angle) * radius * .67);
      canvas.drawLine(
        point,
        point + Offset(math.cos(angle) * 4, math.sin(angle) * 4),
        paint
          ..color = (i.isEven ? accent : const Color(0xFFB8AEFF)).withValues(
            alpha: progress * .65,
          )
          ..strokeWidth = i.isEven ? 3 : 2,
      );
    }
  }

  @override
  bool shouldRepaint(_ActivationArtwork oldDelegate) =>
      progress != oldDelegate.progress ||
      accent != oldDelegate.accent ||
      surface != oldDelegate.surface ||
      line != oldDelegate.line;
}
