/// Owns hover-scrub state: the user's intended (anchor) position and whether
/// a hover-preview is in progress. Pure logic — the player's seek is injected
/// as [seekTo] so this unit-tests without a real VideoPlayerController.
///
/// The widget owns `setState`: it wraps the mutating methods
/// ([seek]/[hoverSeek]/[hoverEnd]/[seekToStart]/[seekToEnd]) in `setState` and
/// renders from [isHovering]/[intendedPosition]. [track] (driven by the player
/// listener) intentionally does NOT trigger a rebuild — it mirrors the old
/// `_trackIntendedPosition`, which updated the field without `setState`.
class HoverScrubController {
  HoverScrubController({required this.seekTo, Duration initialPosition = Duration.zero})
      : _intendedPosition = initialPosition;

  final void Function(Duration position) seekTo;

  Duration _intendedPosition;
  bool _isHovering = false;

  Duration get intendedPosition => _intendedPosition;
  bool get isHovering => _isHovering;

  /// Follow committed playback/seeks while NOT hovering (freezes the anchor
  /// during a hover preview).
  void track(Duration controllerPosition) {
    if (_isHovering) return;
    _intendedPosition = controllerPosition;
  }

  /// A committed seek: clears hover, moves the anchor, seeks.
  void seek(Duration next) {
    _isHovering = false;
    _intendedPosition = next;
    seekTo(next);
  }

  /// A hover preview: enters hovering (anchor frozen) and seeks to preview.
  void hoverSeek(Duration next) {
    _isHovering = true;
    seekTo(next);
  }

  /// Hover ended: restore the anchor and clear hover. No-op if not hovering.
  void hoverEnd() {
    if (!_isHovering) return;
    seekTo(_intendedPosition);
    _isHovering = false;
  }

  void seekToStart() {
    _isHovering = false;
    _intendedPosition = Duration.zero;
    seekTo(Duration.zero);
  }

  /// 1ms back from [duration] so the player doesn't auto-rewind on the next
  /// tick. No-op when [duration] is zero.
  void seekToEnd(Duration duration) {
    _isHovering = false;
    if (duration > Duration.zero) {
      seekTo(duration - const Duration(milliseconds: 1));
    }
  }
}
