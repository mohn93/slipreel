import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

/// Drives a per-frame interpolated playhead position from a
/// `VideoPlayerController`.
///
/// `video_player` only emits position updates every ~250 ms, which makes the
/// playhead "walk" rather than glide. This controller runs a `Ticker` and
/// extrapolates `lastReportedPosition + elapsedWallClock × playbackSpeed`
/// while playing, snapping back to the controller's actual position when
/// paused, when a seek is detected (drift > threshold), or on each native
/// position update while paused.
class SmoothPlayheadController extends ChangeNotifier {
  SmoothPlayheadController({
    required this.videoController,
    required TickerProvider vsync,
  }) {
    _basePosition = videoController.value.position;
    _baseTimestamp = DateTime.now();
    _smoothed = _basePosition;
    _wasPlaying = videoController.value.isPlaying;
    _ticker = vsync.createTicker(_onTick);
    videoController.addListener(_onVideoUpdate);
    _syncTickerToPlayState();
  }

  final VideoPlayerController videoController;

  late final Ticker _ticker;
  late Duration _basePosition;
  late DateTime _baseTimestamp;
  late bool _wasPlaying;
  Duration _smoothed = Duration.zero;

  /// Forward drift this large means video_player jumped ahead of our
  /// extrapolation — almost certainly a forward seek; re-base immediately.
  static const _forwardSeekThreshold = Duration(milliseconds: 250);

  /// Backward drift this large means video_player position is far behind
  /// our extrapolation — only re-base in this case (catches reverse seeks).
  /// Smaller backward drift is decode/reporting jitter and ignoring it
  /// keeps the playhead from glitching backward during playback.
  static const _backwardSeekThreshold = Duration(seconds: -1);

  /// How close to `duration` a paused position has to be before we treat
  /// it as end-of-clip and pin to duration. macOS / video_player report
  /// the *last decoded frame's* timestamp at end-of-playback (often
  /// 16–33ms below duration depending on source fps); without this
  /// snap, the playhead visibly walks backward on the final frame.
  static const _endOfClipTolerance = Duration(milliseconds: 100);

  /// The interpolated playhead position; safe to read every build.
  Duration get position => _smoothed;

  void _onVideoUpdate() {
    final v = videoController.value;
    final isPlaying = v.isPlaying;

    if (isPlaying != _wasPlaying) {
      final pos = isPlaying
          ? v.position
          : resolvePausedPosition(v.position, v.duration);
      _basePosition = pos;
      _baseTimestamp = DateTime.now();
      _wasPlaying = isPlaying;
      _syncTickerToPlayState();
      if (!isPlaying && _smoothed != pos) {
        _smoothed = pos;
        notifyListeners();
      }
      return;
    }

    if (isPlaying) {
      final expected = _basePosition +
          _scale(DateTime.now().difference(_baseTimestamp), v.playbackSpeed);
      final drift = v.position - expected;
      if (drift > _forwardSeekThreshold || drift < _backwardSeekThreshold) {
        _basePosition = v.position;
        _baseTimestamp = DateTime.now();
      }
      // Else: small backward drift is decode jitter — keep extrapolating
      // forward rather than snapping the playhead backward.
    } else {
      // While paused the controller is the source of truth — except at
      // end-of-clip, where the controller reports the last decoded
      // frame's timestamp (slightly below duration). [resolvePausedPosition]
      // pins to duration in that narrow window so the playhead doesn't
      // walk backward on the final frame.
      final pos = resolvePausedPosition(v.position, v.duration);
      if (_smoothed != pos) {
        _smoothed = pos;
        notifyListeners();
      }
    }
  }

  /// When paused, decide whether [position] should be reported as-is
  /// or pinned to [duration]. End-of-clip pins to duration to avoid
  /// the visible backward walk caused by `video_player` reporting the
  /// last decoded frame's timestamp instead of the clip's nominal end.
  ///
  /// The tolerance is tight ([_endOfClipTolerance], 100ms) so an
  /// intentional pause at e.g. 9.5s of a 10s clip is left alone — only
  /// pauses inside the final frame are treated as end-of-clip.
  @visibleForTesting
  static Duration resolvePausedPosition(Duration position, Duration duration) {
    if (duration <= Duration.zero) return position;
    if (position > duration) return duration;
    if (duration - position < _endOfClipTolerance) return duration;
    return position;
  }

  void _syncTickerToPlayState() {
    final shouldRun = videoController.value.isPlaying;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration _) {
    final v = videoController.value;
    var next = _basePosition +
        _scale(DateTime.now().difference(_baseTimestamp), v.playbackSpeed);
    if (next > v.duration) next = v.duration;
    if (next < Duration.zero) next = Duration.zero;
    if (next != _smoothed) {
      _smoothed = next;
      notifyListeners();
    }
  }

  static Duration _scale(Duration d, double factor) {
    return Duration(microseconds: (d.inMicroseconds * factor).round());
  }

  @override
  void dispose() {
    _ticker.dispose();
    videoController.removeListener(_onVideoUpdate);
    super.dispose();
  }
}
