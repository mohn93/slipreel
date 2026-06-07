import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Teardrop pin marker that hangs above a seam between two adjacent
/// slices on the clip lane. Painted via [_PinShapePainter] — top is
/// a rounded cap of width [kBodyWidth*], straight sides converge to a
/// pointed tip at the bottom that points at the seam.
///
/// Two visual states, driven by [hiddenSeconds]:
///   - `Duration.zero` -> compact pin with just the scissors icon.
///   - `> Duration.zero` -> taller / slightly wider pin with the
///     "X.Xs" label STACKED ABOVE the scissors icon (so a row of
///     crowded pins stays narrow horizontally).
///
/// Tap fires [onTap]. The parent (`ClipLane`) chooses what the tap
/// means based on the hidden-seconds value at the seam: > 0 -> clear
/// seam trims; == 0 -> merge the two slices.
///
/// [dragFade] is true while any trim handle in the lane is being
/// dragged AND this marker is NOT the one corresponding to the
/// dragged edge; the marker fades out so the seam region stays
/// visually uncluttered during the drag.
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

  // Hit box is bigger than the painted body so adjacent pins can sit
  // flush against each other in clusters and still be cleanly
  // clickable. The body is bottom-aligned in the hit box so its tip
  // sits at the bottom of the hit box (and therefore at the top edge
  // of the clip lane below).
  static const double kHitWidth = 36;
  static const double kHitHeight = 44;

  // How far above the hit box's bottom edge the body's tip sits.
  // Visually "lifts" the marker off the lane so the tip doesn't
  // touch the clip lane's top edge — gives the seam itself a bit
  // of breathing room between the lane and the pointer.
  static const double kBodyLift = 4;

  // Body dimensions. With label: distinctly bigger so the "X.Xs"
  // pill reads as a deliberate, prominent badge. Without: kept
  // small so a row of cuts-only pins still packs into a tight
  // cluster of teardrops. The rounded cap is always a full circle
  // of diameter = body width; tip height = body height − body
  // width.
  static const double kBodyWidthWithLabel = 34;
  static const double kBodyWidthNoLabel = 22;
  static const double kBodyHeightWithLabel = 40;
  static const double kBodyHeightNoLabel = 26;

  // Vestigial — kept so external callers that historically used it
  // still resolve. The strip itself positions markers internally.
  static const double kPositionedTop = -kHitHeight;

  static const Color _fill = clipFill;
  static const Color _border = Color(0xFFFFFFFF);
  static const Color _shadow = Color(0x66000000);
  static const Duration _fadeDuration = Duration(milliseconds: 180);
  // Slightly longer than the drag-fade so the size change feels
  // deliberate (the eye follows it) rather than blink-and-miss.
  static const Duration _sizeDuration = Duration(milliseconds: 220);
  // One-shot spawn animation that runs only when a brand-new pin is
  // mounted (a fresh cut). Driven by TweenAnimationBuilder, which
  // remembers its end value across rebuilds — so an existing pin that
  // rebuilds (zoom drag, sibling cut, etc.) keeps its settled state
  // instead of replaying the entrance.
  static const Duration _spawnDuration = Duration(milliseconds: 260);
  static const double _spawnSlidePx = 10;

  bool get _showLabel => hiddenSeconds > Duration.zero;

  String _formatLabel() {
    final s = hiddenSeconds.inMilliseconds / 1000.0;
    return '${s.toStringAsFixed(1)}s';
  }

  String _tooltipText() {
    if (_showLabel) return 'Restore ${_formatLabel()} of trimmed content';
    return 'Remove cut';
  }

  /// Vertical-collapse slot — used for the label that sits ABOVE
  /// the scissors icon. As [show] toggles, the slot's height (via
  /// Align heightFactor) animates 0↔1 so the icon below it slides
  /// into place in real time as the label squeezes, instead of
  /// waiting for a fade to finish and then snapping.
  static Widget _collapsingLabelVertical({
    required bool show,
    required Duration duration,
    required Widget child,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: show ? 1.0 : 0.0, end: show ? 1.0 : 0.0),
      duration: duration,
      curve: Curves.easeOut,
      builder: (context, value, c) {
        return ClipRect(
          child: Align(
            heightFactor: value,
            alignment: Alignment.bottomCenter,
            child: Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 3),
                child: c,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bodyWidth = _showLabel ? kBodyWidthWithLabel : kBodyWidthNoLabel;
    final bodyHeight = _showLabel ? kBodyHeightWithLabel : kBodyHeightNoLabel;
    // Reserve the bottom strip of the body for the tip — content
    // stays inside the round cap so it doesn't paint into the
    // converging sides.
    final tipReserve = bodyHeight - bodyWidth;

    final body = AnimatedContainer(
      duration: _sizeDuration,
      curve: Curves.easeOut,
      width: bodyWidth,
      height: bodyHeight,
      child: CustomPaint(
        painter: const _PinShapePainter(
          fillColor: _fill,
          borderColor: _border,
          borderWidth: 1,
          shadowColor: _shadow,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(2, 1, 2, tipReserve + 1),
          // FittedBox(scaleDown) absorbs the tiny font-metric
          // mismatch that can otherwise overflow the round cap by
          // a pixel or two on certain platforms. MainAxisSize.min
          // lets the Column report its intrinsic size so FittedBox
          // can decide whether to scale.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _collapsingLabelVertical(
                  show: _showLabel,
                  duration: _sizeDuration,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      _formatLabel(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                const Icon(
                  Icons.content_cut,
                  key: ValueKey('cut-marker-scissors'),
                  color: Colors.white,
                  size: 11,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Spawn animation: TweenAnimationBuilder starts at 0 on first
    // build and animates to 1 over _spawnDuration. On any subsequent
    // rebuild (with the same end value) it holds steady at 1, so only
    // freshly-mounted markers play the entrance. Sliding UP from
    // below + fade-in reads as "this pin just appeared HERE", which is
    // what we want when a cut commits — the alternative was the prior
    // AnimatedPositioned behavior where an existing key slid across
    // the timeline because the seam index re-pointed at a new spot.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: _spawnDuration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * _spawnSlidePx),
            child: child,
          ),
        );
      },
      child: AnimatedOpacity(
      key: const ValueKey('cut-marker-fade'),
      duration: _fadeDuration,
      curve: Curves.easeOut,
      opacity: dragFade ? 0.2 : 1.0,
      child: Tooltip(
        message: _tooltipText(),
        // Tooltip sits ABOVE the pin — below would overlap the clip
        // lane and get hidden under slice bars on dense seams.
        preferBelow: false,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('cut-marker-hit'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Tooltip.dismissAllToolTips();
              onTap();
            },
            child: SizedBox(
              width: kHitWidth,
              height: kHitHeight,
              // Bottom-align the body, but with [kBodyLift] of bottom
              // padding so the tip sits a few pixels above the lane
              // edge instead of touching it — the marker reads as
              // "hanging above" the seam, not "stuck to" it.
              child: Padding(
                padding: const EdgeInsets.only(bottom: kBodyLift),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: body,
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Paints a teardrop / pin shape sized to its canvas:
///   - Round cap at the top: full circle of diameter = width,
///     centred at (width/2, width/2). Owns the top `width` pixels
///     of the canvas height.
///   - Tip at the bottom: two straight tangent lines from
///     (width/2, height) up to the tangent points on the cap.
///
/// Math: given the cap is a circle of radius r at center (cx, r) and
/// the tip is at (cx, h), the angle alpha at the center between
/// CT (radius to tangent point) and CP (center to tip) satisfies
/// cos(alpha) = r / d where d = h - r is the centre-to-tip distance.
/// The tangent points are mirrored around the vertical axis at
/// (cx ± r·sin(alpha), r + r·cos(alpha)).
///
/// Requires d > r (i.e. h > 2r = width). For shorter shapes the
/// painter degrades to a plain oval so we never crash on tiny
/// sizes.
class _PinShapePainter extends CustomPainter {
  const _PinShapePainter({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
    required this.shadowColor,
  });

  final Color fillColor;
  final Color borderColor;
  final double borderWidth;
  final Color shadowColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final r = w / 2;
    final cx = w / 2;
    final cy = r;

    final Path path;
    final d = h - cy;
    if (d <= r) {
      // Not enough room for a tip — degrade to an oval so we don't
      // produce a zero-tangent path.
      path = Path()
        ..addOval(Rect.fromLTWH(0, 0, w, h));
    } else {
      final alpha = math.acos(r / d);
      final s = math.sin(alpha);
      final c = math.cos(alpha);
      final rTan = Offset(cx + r * s, cy + r * c);
      final lTan = Offset(cx - r * s, cy + r * c);
      final tip = Offset(cx, h);

      path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(rTan.dx, rTan.dy)
        // Long-way arc from rTan over the TOP of the cap to lTan.
        // In Flutter screen coords (Y down) this sweep is CCW.
        ..arcToPoint(
          lTan,
          radius: Radius.circular(r),
          largeArc: true,
          clockwise: false,
        )
        ..close();
    }

    // Soft drop shadow — drawn as a blurred copy of the path shifted
    // down a hair. Two layers (wider+softer, narrower+denser) keep
    // adjacent pins separable when they're touching.
    final softShadow = Paint()
      ..color = shadowColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.save();
    canvas.translate(0, 2);
    canvas.drawPath(path, softShadow);
    canvas.restore();

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(path, fillPaint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(_PinShapePainter old) =>
      old.fillColor != fillColor ||
      old.borderColor != borderColor ||
      old.borderWidth != borderWidth ||
      old.shadowColor != shadowColor;
}
