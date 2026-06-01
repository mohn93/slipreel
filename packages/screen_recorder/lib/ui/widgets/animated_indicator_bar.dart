import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Vertical accent bar that spring-translates between row positions in
/// a stacked column of equal-height items. Renders one rectangle whose
/// top edge tweens to the center of [selectedIndex]'s row.
///
/// The widget paints itself the size of the full column footprint:
///   width  = leftInset + barWidth
///   height = itemHeight * itemCount + itemGap * (itemCount - 1)
///
/// Used by the inspector rail today; reusable wherever a vertical tab
/// strip needs an accent indicator (settings tabs, future side rails).
class AnimatedIndicatorBar extends StatefulWidget {
  const AnimatedIndicatorBar({
    super.key,
    required this.selectedIndex,
    required this.itemCount,
    required this.itemHeight,
    required this.itemGap,
    this.barWidth = 3,
    this.barHeightFraction = 0.6,
    this.leftInset = 4,
  });

  /// -1 means "no selection" — the bar fades out.
  final int selectedIndex;
  final int itemCount;
  final double itemHeight;
  final double itemGap;
  final double barWidth;

  /// Bar's vertical extent as a fraction of [itemHeight]. 0.6 ≈ 24 px
  /// on a 40 px row.
  final double barHeightFraction;

  /// Distance from the widget's left edge to the bar's left edge.
  final double leftInset;

  @override
  State<AnimatedIndicatorBar> createState() => _AnimatedIndicatorBarState();
}

class _AnimatedIndicatorBarState extends State<AnimatedIndicatorBar> {
  int? _previousIndex;

  @override
  void didUpdateWidget(covariant AnimatedIndicatorBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _previousIndex = oldWidget.selectedIndex;
    }
  }

  double _targetTop(int index) {
    final centerY = (widget.itemHeight + widget.itemGap) * index +
        widget.itemHeight / 2;
    final barHeight = widget.itemHeight * widget.barHeightFraction;
    return centerY - barHeight / 2;
  }

  @override
  Widget build(BuildContext context) {
    final barHeight = widget.itemHeight * widget.barHeightFraction;
    final width = widget.leftInset + widget.barWidth;
    final height = widget.itemHeight * widget.itemCount +
        widget.itemGap * (widget.itemCount - 1);

    final isVisible = widget.selectedIndex >= 0;
    final targetTop = isVisible ? _targetTop(widget.selectedIndex) : 0.0;
    final beginTop =
        _previousIndex != null ? _targetTop(_previousIndex!) : targetTop;
    // First mount snaps; subsequent rebuilds glide on easeOutQuint to
    // match the alert deck and other app-wide transitions — no spring
    // overshoot.
    final duration = _previousIndex == null
        ? Duration.zero
        : const Duration(milliseconds: 280);

    return SizedBox(
      width: width,
      height: height,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        opacity: isVisible ? 1.0 : 0.0,
        child: Stack(
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: beginTop, end: targetTop),
              duration: duration,
              curve: Curves.easeOutQuint,
              builder: (context, top, _) {
                return Positioned(
                  top: top,
                  left: widget.leftInset,
                  width: widget.barWidth,
                  height: barHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.palette.accent,
                      borderRadius: BorderRadius.circular(widget.barWidth / 2),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

