import 'package:cue/cue.dart';
import 'package:flutter/material.dart';

/// Three vertical bars that bounce in a staggered ripple — the
/// equalizer-style loading indicator that fits a music-player aesthetic
/// (and a CTA button) better than a generic spinner.
///
/// Each bar stretches between [_minScale] and full height on its own
/// 600 ms ping-pong cycle, offset by [_staggerMs] so the wave runs
/// left-to-right. The whole animation is driven by `cue`'s declarative
/// [Cue.onMount] with `repeat: true, reverseOnRepeat: true` — no
/// AnimationController or vsync plumbing required.
class CtaSpinner extends StatelessWidget {
  const CtaSpinner({
    super.key,
    this.size = 18,
    this.color = Colors.white,
  });

  /// Outer footprint — total widget height. Bars get ~3/4 of this,
  /// gaps fill the rest, so the indicator visually matches an icon
  /// of the same size when dropped in a button's icon slot.
  final double size;

  /// Bar colour. Defaults to white so it reads on the indigo CTA.
  final Color color;

  // 3 bars, each animating between [_minScale] × full height and
  // full height. Min scale is small enough that the "down" frame
  // reads as a single dot, large enough that the bar doesn't
  // collapse into a hairline.
  static const double _minScale = 0.35;

  // Time for one direction of the ping-pong. With reverseOnRepeat
  // the full up-down cycle is 2× this. 320 ms feels lively without
  // looking frantic.
  static const Duration _halfPeriod = Duration(milliseconds: 320);

  // Phase offset between adjacent bars. 110 ms ≈ 1/3 of a half-period
  // so each bar peaks at a distinct moment.
  static const Duration _staggerMs = Duration(milliseconds: 110);

  @override
  Widget build(BuildContext context) {
    final barHeight = size * 0.85;
    final barWidth = (size * 0.16).clamp(2.0, 4.0);
    final gap = (size * 0.12).clamp(2.0, 4.0);
    return SizedBox(
      width: barWidth * 3 + gap * 2,
      height: size,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Bar(
            width: barWidth,
            height: barHeight,
            color: color,
            delay: Duration.zero,
            period: _halfPeriod,
            minScale: _minScale,
          ),
          SizedBox(width: gap),
          _Bar(
            width: barWidth,
            height: barHeight,
            color: color,
            delay: _staggerMs,
            period: _halfPeriod,
            minScale: _minScale,
          ),
          SizedBox(width: gap),
          _Bar(
            width: barWidth,
            height: barHeight,
            color: color,
            delay: _staggerMs * 2,
            period: _halfPeriod,
            minScale: _minScale,
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.width,
    required this.height,
    required this.color,
    required this.delay,
    required this.period,
    required this.minScale,
  });

  final double width;
  final double height;
  final Color color;
  final Duration delay;
  final Duration period;
  final double minScale;

  @override
  Widget build(BuildContext context) {
    return Cue.onMount(
      repeat: true,
      reverseOnRepeat: true,
      motion: CueMotion.curved(period, curve: Curves.easeInOut),
      acts: [
        StretchAct(
          from: Stretch(x: 1.0, y: minScale),
          to: const Stretch(x: 1.0, y: 1.0),
          alignment: Alignment.center,
          delay: delay,
        ),
      ],
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(width / 2),
        ),
      ),
    );
  }
}
