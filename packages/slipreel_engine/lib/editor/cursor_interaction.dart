import 'dart:ui';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// What the user was doing during one press→release gesture.
///
/// Kinds are derived from the natively captured [CursorState] plus the
/// gesture's own geometry — never from post-hoc trajectory inference.
/// A click landing while the pointer reads [CursorState.iBeam] *is* a
/// text-field click; no heuristic beats reading it directly.
enum InteractionKind {
  /// Stationary press on something that isn't text.
  click,

  /// Stationary press while the pointer reads I-beam — a text field
  /// gaining focus. The interesting content is the typing that follows.
  textEntry,

  /// Press, travel, release. Slider drags, window moves, canvas panning.
  drag,

  /// A predominantly horizontal drag while the pointer reads I-beam.
  /// The interesting content is the swept line, not the press point.
  textSelection,
}

/// One recognised press→release gesture extracted from a
/// `CursorRecording` by [InteractionClassifier].
class CursorInteraction {
  const CursorInteraction({
    required this.kind,
    required this.start,
    required this.end,
    required this.anchor,
    required this.sweptBounds,
    required this.state,
  });

  final InteractionKind kind;

  /// Press time (isClicked rising edge), in source time.
  final Duration start;

  /// Time of the LAST sample at which the button was still down — not
  /// the first unclicked sample after it. That keeps [end] consistent
  /// with [sweptBounds], which is also computed over the clicked samples
  /// only. Equal to [start] for a gesture that begins and ends within
  /// one sample; equal to the recording's last sample time for a press
  /// that never releases.
  final Duration end;

  /// Cursor position at the press.
  final Offset anchor;

  /// Bounding box of the cursor path from press to release. Degenerates
  /// to a zero-size rect at [anchor] for a stationary click, so
  /// consumers can treat clicks and drags uniformly instead of branching.
  final Rect sweptBounds;

  /// Dominant pointer state in the window just before the press.
  final CursorState state;

  /// How long the gesture itself lasted. Zero for an instantaneous click.
  Duration get gesture => end - start;
}
