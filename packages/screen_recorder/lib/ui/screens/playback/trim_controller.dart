import 'package:slipreel_engine/models/trim_selection.dart';

/// Owns the trim selection and soft-enforces it during playback: when the
/// playhead crosses `trim.end` while playing, it pauses and parks at the end.
/// Player ops are injected so this unit-tests without a VideoPlayerController.
class TrimController {
  TrimController({required this.pause, required this.seekTo});

  final void Function() pause;
  final void Function(Duration position) seekTo;

  /// Current trim selection (null until the video initializes / when cleared).
  TrimSelection? selection;

  /// Called on each player tick. Soft-enforces the trim end while playing.
  void enforce({required bool isPlaying, required Duration position}) {
    final trim = selection;
    if (trim == null || !isPlaying) return;
    if (position >= trim.end) {
      pause();
      seekTo(trim.end);
    }
  }
}
