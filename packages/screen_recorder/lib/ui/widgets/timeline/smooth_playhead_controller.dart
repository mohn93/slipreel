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

  static const _seekDriftThreshold = Duration(milliseconds: 250);

  /// The interpolated playhead position; safe to read every build.
  Duration get position => _smoothed;

  void _onVideoUpdate() {
    final v = videoController.value;
    final isPlaying = v.isPlaying;

    if (isPlaying != _wasPlaying) {
      _basePosition = v.position;
      _baseTimestamp = DateTime.now();
      _wasPlaying = isPlaying;
      _syncTickerToPlayState();
      if (!isPlaying && _smoothed != v.position) {
        _smoothed = v.position;
        notifyListeners();
      }
      return;
    }

    if (isPlaying) {
      // Detect seeks (or large reporting drift) and re-base extrapolation.
      final expected = _basePosition +
          _scale(DateTime.now().difference(_baseTimestamp), v.playbackSpeed);
      final drift = (v.position - expected).abs();
      if (drift > _seekDriftThreshold) {
        _basePosition = v.position;
        _baseTimestamp = DateTime.now();
      }
    } else {
      // While paused the controller is the source of truth.
      if (_smoothed != v.position) {
        _smoothed = v.position;
        notifyListeners();
      }
    }
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
