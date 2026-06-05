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
  // Two-layer shadow: a wide soft halo + a tight contact shadow. Together
  // they keep each pin visually separable when two pins overlap on short
  // slices — the halo reads as "this pin sits above the other one" and
  // the contact shadow keeps the lower pin from looking glued to the lane.
  static const Color _shadowSoft = Color(0x55000000);
  static const Color _shadowContact = Color(0x88000000);
  static const Duration _fadeDuration = Duration(milliseconds: 180);
  // Duration for the pill body's size / label transitions. Slightly
  // longer than the drag-fade so the size change feels deliberate
  // (the eye follows it) rather than blink-and-miss.
  static const Duration _sizeDuration = Duration(milliseconds: 220);

  bool get _showLabel => hiddenSeconds > Duration.zero;

  String _formatLabel() {
    final s = hiddenSeconds.inMilliseconds / 1000.0;
    return '${s.toStringAsFixed(1)}s';
  }

  String _tooltipText() {
    if (_showLabel) return 'Restore ${_formatLabel()} of trimmed content';
    return 'Remove cut';
  }

  /// Wraps [child] in a tween-driven slot whose width factor goes
  /// 0↔1 in lockstep with [show]. Per frame the slot reports its
  /// current width to the parent Row, so the icon next to it slides
  /// into place IMMEDIATELY as the label shrinks — instead of
  /// waiting for a fade transition to complete and then snapping.
  /// Also fades + slides the child down as it collapses.
  static Widget _collapsingLabel({
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
            widthFactor: value,
            alignment: AlignmentDirectional.centerStart,
            child: Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 4),
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
    // AnimatedContainer eases the body's padding (8 vs 4 px) when
    // the label toggles on/off. AnimatedSize wraps the Row so its
    // intrinsic width animates smoothly as the label appears /
    // disappears — the icon stays put while the pill breathes
    // around it. AnimatedSwitcher with fade+slide handles the label
    // itself so it doesn't pop in or out.
    final body = AnimatedContainer(
      duration: _sizeDuration,
      curve: Curves.easeOut,
      height: kBodyHeight,
      padding: EdgeInsets.symmetric(horizontal: _showLabel ? 8 : 4),
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(kBodyHeight / 2),
        border: Border.all(color: _border, width: 1),
        boxShadow: const [
          BoxShadow(
            color: _shadowSoft,
            blurRadius: 10,
            spreadRadius: 1,
            offset: Offset(0, 4),
          ),
          BoxShadow(
            color: _shadowContact,
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      // FittedBox(scaleDown) lets narrow hit slots gracefully scale
      // the label-and-icon row down if needed. The label collapses
      // its OWN width via Align(widthFactor:) tweened in real time
      // — so the icon to its right tracks the squeeze frame-by-frame
      // and slides into its centred resting position alongside the
      // fade+slide-down of the label.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _collapsingLabel(
              show: _showLabel,
              duration: _sizeDuration,
              child: Padding(
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

    // Tail (pointer) is intentionally removed for now — the body
    // alone reads cleanly as a marker.
    final pin = body;

    return AnimatedOpacity(
      key: const ValueKey('cut-marker-fade'),
      duration: _fadeDuration,
      curve: Curves.easeOut,
      opacity: dragFade ? 0.2 : 1.0,
      child: Tooltip(
        message: _tooltipText(),
        // Tooltip sits ABOVE the pin — below would overlap the clip
        // lane and get hidden under slice bars on dense seams.
        preferBelow: false,
        // After the tap the tooltip used to linger because pointer
        // didn't "leave" (mouse stays parked on the marker that just
        // mutated). Snap it shut on the action so it never overlaps
        // the user's next move.
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
              child: Center(child: pin),
            ),
          ),
        ),
      ),
    );
  }
}

