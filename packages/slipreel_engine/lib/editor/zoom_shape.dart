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
  /// the `ZoomRegion` Smart defaults (`FollowMode.smart`, deadzone 0.8) —
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

/// Per-kind shapes. `click` preserves the envelope from the pre-classifier
/// detector (1.5×, 500ms lead-in, 1800ms hold, 500ms lead-out), but now
/// follows the cursor, where the historic detector was anchored.
const Map<InteractionKind, ZoomShape> kZoomShapes = {
  // NOTE: `AutoZoomDetector` does NOT read this row in production — it
  // rebuilds the click shape from its own `zoomLevel`/`leadIn`/`hold`/
  // `leadOut` constructor parameters (see `_shapeFor`), which exist to
  // preserve the historic defaults. Editing this row alone changes
  // nothing; change the detector's defaults too. The two are pinned
  // together by `auto_zoom_detector_shape_test.dart`.
  InteractionKind.click: ZoomShape(
    zoomLevel: 1.5,
    leadIn: Duration(milliseconds: 500),
    hold: Duration(milliseconds: 1800),
    leadOut: Duration(milliseconds: 500),
    followCursor: true,
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
  // A selection is FRAMED, not followed. [fitToSweptBounds] exists to
  // compute a centre that holds the whole swept range in shot, and the
  // zoom is capped so that range fits — so there is nothing left for a
  // follow camera to chase. Worse, `ZoomFocalController` ignores
  // `rect.center` entirely once `followCursor` is true (it parks at the
  // video centre and chases the cursor instead), which threw the fitted
  // centre away. Anchored is the only setting under which the fit means
  // anything.
  InteractionKind.textSelection: ZoomShape(
    zoomLevel: 1.7,
    leadIn: Duration(milliseconds: 450),
    hold: Duration(milliseconds: 700),
    leadOut: Duration(milliseconds: 500),
    followCursor: false,
    holdTracksGesture: true,
    fitToSweptBounds: true,
  ),
};
