import 'cursor_interaction.dart';

/// Region parameters for one [InteractionKind] — the surface that gets
/// tuned. Kept out of `AutoZoomDetector` so changing the feel of
/// auto-zoom doesn't mean reading the detector's control flow.
class ZoomShape {
  const ZoomShape({
    required this.zoomLevel,
    required this.leadIn,
    required this.hold,
    required this.leadOut,
    required this.followCursor,
    required this.holdTracksGesture,
    required this.fitToSweptBounds,
  });

  /// Preferred magnification. For [fitToSweptBounds] shapes this is an
  /// upper bound — the detector caps it so the swept content fits.
  final double zoomLevel;

  final Duration leadIn;

  /// Held duration between the enter and exit ramps. When
  /// [holdTracksGesture] is true this is a *tail* added to the gesture's
  /// own length rather than the total.
  final Duration hold;

  final Duration leadOut;

  /// Whether the region's camera follows the cursor. Follow regions use
  /// the `ZoomRegion` defaults (`FollowMode.bounded`, deadzone 0.8) —
  /// they ride the stack that is already tuned rather than adding a new
  /// tuning surface.
  final bool followCursor;

  /// True for gesture kinds whose interesting duration is set by the
  /// gesture itself rather than a constant.
  final bool holdTracksGesture;

  /// True when the region should frame the gesture's swept bounds
  /// instead of centring on its press point.
  final bool fitToSweptBounds;

  /// Ceiling on a gesture-tracking hold, so a 30-second canvas pan
  /// doesn't zoom the entire video.
  static const Duration maxHold = Duration(seconds: 6);

  Duration effectiveHold(Duration gesture) {
    if (!holdTracksGesture) return hold;
    final total = gesture + hold;
    return total > maxHold ? maxHold : total;
  }
}

/// Per-kind shapes. `click` mirrors the historic auto-zoom defaults, so a
/// solitary unclassified click produces a byte-identical region to the
/// pre-classifier detector.
const Map<InteractionKind, ZoomShape> kZoomShapes = {
  InteractionKind.click: ZoomShape(
    zoomLevel: 1.5,
    leadIn: Duration(milliseconds: 500),
    hold: Duration(milliseconds: 1800),
    leadOut: Duration(milliseconds: 500),
    followCursor: false,
    holdTracksGesture: false,
    fitToSweptBounds: false,
  ),
  // Tighter and longer than a click: text is what the viewer is being
  // asked to read, and the interesting content — the typing — happens
  // after the click, not at it.
  InteractionKind.textEntry: ZoomShape(
    zoomLevel: 1.8,
    leadIn: Duration(milliseconds: 500),
    hold: Duration(milliseconds: 2600),
    leadOut: Duration(milliseconds: 600),
    followCursor: false,
    holdTracksGesture: false,
    fitToSweptBounds: false,
  ),
  // Looser than a click because the gesture covers ground, and timed off
  // the gesture rather than a constant.
  InteractionKind.drag: ZoomShape(
    zoomLevel: 1.4,
    leadIn: Duration(milliseconds: 450),
    hold: Duration(milliseconds: 800),
    leadOut: Duration(milliseconds: 500),
    followCursor: true,
    holdTracksGesture: true,
    fitToSweptBounds: false,
  ),
  InteractionKind.textSelection: ZoomShape(
    zoomLevel: 1.7,
    leadIn: Duration(milliseconds: 450),
    hold: Duration(milliseconds: 700),
    leadOut: Duration(milliseconds: 500),
    followCursor: true,
    holdTracksGesture: true,
    fitToSweptBounds: true,
  ),
};
