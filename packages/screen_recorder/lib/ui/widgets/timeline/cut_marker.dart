import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Pin marker that hangs above a seam between two adjacent slices on
/// the clip lane.
///
/// Two visual states, driven by [hiddenSeconds]:
///   - `Duration.zero` -> compact pin with just the scissors icon.
///   - `> Duration.zero` -> wider pin with a leading "X.Xs" label.
///
/// Tap fires [onTap]. The parent (`ClipLane`) chooses what the tap
/// means based on the hidden-seconds value at the seam: > 0 -> clear
/// seam trims; == 0 -> merge the two slices.
///
/// [dragFade] is true while any trim handle in the lane is being
/// dragged; the marker fades out so the seam region stays visually
/// uncluttered during the drag.
class CutMarker extends StatelessWidget {
  const CutMarker({
    super.key,
    required this.hiddenSeconds,
    required this.onTap,
    this.dragFade = false,
  });

  final Duration hiddenSeconds;
  final VoidCallback onTap;
  final bool dragFade;

  static const double kHitWidth = 64;
  static const double kHitHeight = 36;
  static const double kBodyHeight = 22;
  static const double kTipHeight = 6;
  static const double kHangAbove = 10;
  // y to pass to a Positioned wrapper so the tip point sits exactly
  // kHangAbove px above the parent's top edge. Derived from the body
  // and tip heights plus the vertical centering padding inside the
  // fixed-size hit box (kHitHeight - kBodyHeight - kTipHeight) / 2.
  // = -(10 + 22 + 6 + (36-22-6)/2) = -42.
  static const double kPositionedTop = -42;

  static const Color _fill = clipFill;
  static const Color _border = Color(0xFFFFFFFF);
  static const Color _shadow = Color(0x66000000);
  static const Duration _fadeDuration = Duration(milliseconds: 180);

  bool get _showLabel => hiddenSeconds > Duration.zero;

  String _formatLabel() {
    final s = hiddenSeconds.inMilliseconds / 1000.0;
    return '${s.toStringAsFixed(1)}s';
  }

  String _tooltipText() {
    if (_showLabel) return 'Restore ${_formatLabel()} of trimmed content';
    return 'Remove cut';
  }

  @override
  Widget build(BuildContext context) {
    final body = Container(
      height: kBodyHeight,
      padding: EdgeInsets.symmetric(horizontal: _showLabel ? 8 : 4),
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(kBodyHeight / 2),
        border: Border.all(color: _border, width: 1),
        boxShadow: const [
          BoxShadow(
            color: _shadow,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showLabel)
              Padding(
                key: const ValueKey('cut-marker-label'),
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  _formatLabel(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ),
            const Icon(
              Icons.content_cut,
              key: ValueKey('cut-marker-scissors'),
              color: Colors.white,
              size: 12,
            ),
          ],
        ),
      ),
    );

    final pin = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        body,
        SizedBox(
          height: kTipHeight,
          width: 8,
          child: CustomPaint(
            painter: const _PinTipPainter(fill: _fill, border: _border),
          ),
        ),
      ],
    );

    return AnimatedOpacity(
      key: const ValueKey('cut-marker-fade'),
      duration: _fadeDuration,
      curve: Curves.easeOut,
      opacity: dragFade ? 0.2 : 1.0,
      child: Tooltip(
        message: _tooltipText(),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('cut-marker-hit'),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox(
              width: kHitWidth,
              height: kHitHeight,
              child: Center(child: pin),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinTipPainter extends CustomPainter {
  const _PinTipPainter({required this.fill, required this.border});

  final Color fill;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _PinTipPainter old) =>
      old.fill != fill || old.border != border;
}
