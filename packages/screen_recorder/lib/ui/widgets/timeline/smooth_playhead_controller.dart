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
class SmoothPlayheadController extends ChangeNotifier
    implements ValueListenable<Duration> {
  SmoothPlayheadController({
    required this.videoController,
    required TickerProvider vsync,
  }) {
    _basePosition = videoController.value.position;
    _baseTimestamp = DateTime.now();
    _smoothed = _basePosition;
    _wasPlaying = videoController.value.isPlaying;
    _lastPlaybackSpeed = videoController.value.playbackSpeed;
    _ticker = vsync.createTicker(_onTick);
    videoController.addListener(_onVideoUpdate);
    _syncTickerToPlayState();
  }

  final VideoPlayerController videoController;

  late final Ticker _ticker;
  late Duration _basePosition;
  late DateTime _baseTimestamp;
  late bool _wasPlaying;
  // Last observed VideoPlayerController.playbackSpeed. Rebasing on
  // change is what keeps the extrapolation continuous at slice
  // boundaries — see [_onVideoUpdate].
  late double _lastPlaybackSpeed;
  Duration _smoothed = Duration.zero;

  // Set by [snapForward] when the application logic seeks the player
  // past a trim gap. While non-null, [_onVideoUpdate] ignores reports
  // of `v.position` below this threshold — the player's reported
  // position lags the seek by 50–200 ms while the target frame decodes,
  // and treating those stale reports as backward drift would undo the
  // forward snap and produce a back-and-forth oscillation at the seam.
  // Cleared when `v.position` finally catches up to or past the
  // threshold (the seek landed) — see [_onVideoUpdate].
  Duration? _suppressBackwardDriftBelow;

  // A seek initiated by the editor (timeline click, transport jump, hover
  // preview) must update the extrapolator immediately. The native player
  // reports its old position until the target frame has decoded; without
  // this latch, that stale report can either undo the visual seek or be
  // mistaken for ordinary decoder jitter. The latter is especially visible
  // for backward seeks under [_backwardSeekThreshold]: the video seeks, but
  // the playhead appears not to respond at all.
  //
  // The generation makes rapid consecutive seeks safe. Completion of an
  // older native seek cannot release the latch owned by the newest click.
  int _applicationSeekGeneration = 0;
  bool _applicationSeekPending = false;
  bool _disposed = false;

  // True while the playhead is frozen at the position it held the instant the
  // user paused, rather than tracking `v.position`. `video_player` only polls
  // the native position every ~100 ms and stops polling on pause, so its last
  // sample lags real playback and never catches up — snapping to it nudges the
  // playhead backward from where the user just saw it. We hold the smoothed
  // estimate instead. Cleared by any authoritative move (resume, our seekTo,
  // snapForward) and by a direct videoController.seekTo detected through
  // [_heldPollBaseline].
  bool _holdPausedPlayhead = false;
  // The video_player position poll captured at the pause instant — the value
  // we hold AGAINST. This poll is frozen while paused, so if v.position later
  // differs, an external (direct) seek moved the player and the hold releases.
  Duration _heldPollBaseline = Duration.zero;

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

  /// `ValueListenable<Duration>` plumbing: lets callers thread this
  /// controller directly into `ValueListenableBuilder` so only the
  /// playhead subtree rebuilds per vsync. Aliases [position].
  @override
  Duration get value => _smoothed;

  /// Current base position used by the extrapolator. Exposed for unit
  /// tests asserting the rebase-on-speed-change contract.
  @visibleForTesting
  Duration get basePosition => _basePosition;

  /// Last observed `value.playbackSpeed`. Exposed for unit tests.
  @visibleForTesting
  double get lastPlaybackSpeed => _lastPlaybackSpeed;

  /// Pure helper documenting the rebase-on-speed-change contract: when
  /// `value.playbackSpeed` flips, the new base is the CURRENT smoothed
  /// position — NOT `value.position`. The controller reports position
  /// with up to one tick (~125–250 ms) of latency, so rebasing to
  /// `value.position` snaps the playhead backward by that latency. Using
  /// the smoothed value keeps the slope changing without a discontinuity.
  @visibleForTesting
  static Duration rebaseBaseOnSpeedChange({
    required Duration currentSmoothed,
  }) => currentSmoothed;

  /// Pure helper documenting the [snapForward] no-op contract: a snap
  /// only advances state when the requested target is strictly greater
  /// than the current smoothed value. Equality is a no-op (we're
  /// already there) and a backward target is a no-op (we don't undo
  /// progress through a snap call). The caller doesn't need to gate on
  /// this — calling snapForward with an at-or-before target is safe.
  @visibleForTesting
  static bool snapForwardWouldAdvance({
    required Duration target,
    required Duration currentSmoothed,
  }) => target > currentSmoothed;

  /// Pure helper documenting the suppress-backward-drift contract:
  /// after [snapForward] sets `suppressBelow`, the player's reported
  /// `v.position` lags the seek by 50–200 ms while the target frame
  /// decodes. Reports BELOW the threshold are stale (the in-flight
  /// seek hasn't landed yet) and must be ignored so they don't snap
  /// the smoothed value backward into the trim gap, producing a
  /// visible oscillation at the seam. The suppression clears the
  /// instant `v.position` catches up to or exceeds the threshold.
  @visibleForTesting
  static bool shouldClearBackwardDriftSuppression({
    required Duration vPosition,
    required Duration suppressBelow,
  }) => vPosition >= suppressBelow;

  /// Called when application logic seeks the player past a stretch of
  /// source time that should not be played through (e.g. a trim gap
  /// between two slices' playable ranges). Sets the smoothed position
  /// to [target] immediately and suppresses [v.position] reports below
  /// [target] from triggering backward drift correction until the seek
  /// actually lands. Without this, the smoothed value would walk
  /// forward off the gap-position base while the player's seek decodes,
  /// then snap back to v.position the instant a stale gap-position
  /// update arrives — producing a visible oscillation at the seam.
  ///
  /// Idempotent if [target] is equal to or below the current smoothed
  /// position (no-op) — the caller doesn't need to gate on "did we
  /// already snap to this target".
  void snapForward(Duration target) {
    if (!snapForwardWouldAdvance(target: target, currentSmoothed: _smoothed)) {
      return;
    }
    _basePosition = target;
    _baseTimestamp = DateTime.now();
    _suppressBackwardDriftBelow = target;
    _smoothed = target;
    // This is an authoritative move — the paused-hold no longer applies.
    _holdPausedPlayhead = false;
    notifyListeners();
  }

  /// Seeks the native player while moving the smoothed playhead to [target]
  /// synchronously.
  ///
  /// Keep all user-driven seeks on this path instead of calling
  /// [videoController.seekTo] directly. Native seek completion can take a few
  /// frames; during that window [_onVideoUpdate] ignores the player's stale
  /// pre-seek position so a nearby backward/forward click cannot be filtered
  /// out as playback jitter.
  Future<void> seekTo(Duration target) async {
    final duration = videoController.value.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && target > duration
        ? duration
        : target;
    final generation = ++_applicationSeekGeneration;
    _applicationSeekPending = true;
    // An explicit user seek supersedes any trim-gap forward-snap latch and the
    // paused-hold — the seeked position is authoritative, so once it lands the
    // paused branch should trust the reported (now-accurate) position again.
    _suppressBackwardDriftBelow = null;
    _holdPausedPlayhead = false;
    _basePosition = clamped;
    _baseTimestamp = DateTime.now();
    if (_smoothed != clamped) {
      _smoothed = clamped;
      notifyListeners();
    }

    var completed = false;
    try {
      await videoController.seekTo(clamped);
      completed = true;
    } finally {
      // A newer click owns the latch now. Do not let this older completion
      // release it or rebase the playhead away from the newer target.
      if (!_disposed && generation == _applicationSeekGeneration) {
        _applicationSeekPending = false;
        if (completed) {
          // video_player has published the landed position by the time its
          // seek future completes. Re-run normal reconciliation now that
          // stale reports are allowed again.
          _onVideoUpdate();
        } else {
          // A failed seek should not strand the visual playhead at a frame
          // the native player never reached.
          final actual = videoController.value.position;
          _basePosition = actual;
          _baseTimestamp = DateTime.now();
          if (_smoothed != actual) {
            _smoothed = actual;
            notifyListeners();
          }
        }
      }
    }
  }

  void _onVideoUpdate() {
    final v = videoController.value;
    final isPlaying = v.isPlaying;

    // Rebase on every playbackSpeed change. video_player's setPlaybackSpeed
    // flips `value.playbackSpeed` synchronously, but _basePosition /
    // _baseTimestamp are stale, so without this the next extrapolation
    // tick's slope changes while the base is unchanged — producing a
    // visible discontinuity ("jump then slow back") at slice boundaries
    // when adjacent slices have different speeds.
    //
    // Use [_smoothed] (the current extrapolated value) as the new base,
    // NOT `v.position`. The controller reports position with up to
    // ~250 ms of latency, so `v.position` at this instant is the
    // playback head's position one tick ago — rebasing to it would
    // snap the playhead BACKWARD by that latency, producing the new
    // jitter pattern. The smoothed value is, by construction, our best
    // estimate of "now", so using it changes the slope without changing
    // the y-intercept. Native AVPlayer's rate-change latency (~1 frame)
    // produces only a small forward drift, well under the
    // [_forwardSeekThreshold] — so no forward re-snap follows either.
    if (v.playbackSpeed != _lastPlaybackSpeed) {
      _basePosition = _smoothed;
      _baseTimestamp = DateTime.now();
      _lastPlaybackSpeed = v.playbackSpeed;
    }

    if (_applicationSeekPending) {
      // Preserve play/pause ticker correctness if transport state happens to
      // change while the native seek is decoding, but never reconcile
      // position against the stale pre-seek timestamp.
      if (isPlaying != _wasPlaying) {
        _wasPlaying = isPlaying;
        _syncTickerToPlayState();
      }
      return;
    }

    if (isPlaying != _wasPlaying) {
      // Both edges anchor to the smoothed estimate, never video_player's
      // position poll. That poll lags playback by up to a poll interval, is
      // frozen while paused, and (on resume) is not refreshed until ~100ms
      // after play() restarts the poll timer — so anchoring to it snaps the
      // playhead visibly backward both when pausing and when resuming. The
      // smoothed value is our continuous best estimate across the transition.
      final pos = isPlaying
          ? _smoothed
          : resolvePausedPosition(_smoothed, v.duration);
      _basePosition = pos;
      _baseTimestamp = DateTime.now();
      _wasPlaying = isPlaying;
      _holdPausedPlayhead = !isPlaying;
      // Remember the poll value we're choosing to ignore. While paused, this
      // is the only thing video_player keeps reporting; a change away from it
      // means an external seek landed (see the paused branch below).
      if (!isPlaying) _heldPollBaseline = v.position;
      _syncTickerToPlayState();
      if (!isPlaying && _smoothed != pos) {
        _smoothed = pos;
        notifyListeners();
      }
      return;
    }

    if (isPlaying) {
      // After [snapForward], the player's reported position lags the
      // seek by 50–200 ms while the target frame decodes. Treating
      // those stale "still in the gap" reports as backward drift would
      // undo the forward snap, so we ignore drift until v.position
      // catches up to the snap target.
      if (_suppressBackwardDriftBelow != null) {
        if (shouldClearBackwardDriftSuppression(
          vPosition: v.position,
          suppressBelow: _suppressBackwardDriftBelow!,
        )) {
          _suppressBackwardDriftBelow = null;
        } else {
          return;
        }
      }
      final expected =
          _basePosition +
          _scale(DateTime.now().difference(_baseTimestamp), v.playbackSpeed);
      final drift = v.position - expected;
      if (drift > _forwardSeekThreshold || drift < _backwardSeekThreshold) {
        _basePosition = v.position;
        _baseTimestamp = DateTime.now();
      }
      // Else: small backward drift is decode jitter — keep extrapolating
      // forward rather than snapping the playhead backward.
    } else {
      // While paused we hold the position captured at the pause instant (see
      // _holdPausedPlayhead) rather than re-snapping to video_player's stale,
      // frozen position poll on incidental controller updates.
      if (_holdPausedPlayhead) {
        // ...but a direct videoController.seekTo while paused (one that
        // bypasses our own seekTo — e.g. slice-nav, add-zoom, trim parking)
        // changes v.position to a genuinely new value the player just sought
        // to. That IS authoritative: drop the hold and reconcile so the
        // marker follows the seeked frame instead of freezing. The frozen
        // pause-time poll never changes, so an unchanged value stays held.
        if (v.position == _heldPollBaseline) return;
        _holdPausedPlayhead = false;
      }
      // The controller is the source of truth — except at end-of-clip, where
      // it reports the last decoded frame's timestamp (slightly below
      // duration). [resolvePausedPosition] pins to duration in that narrow
      // window so the playhead doesn't walk backward on the final frame.
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
    var next =
        _basePosition +
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
    _disposed = true;
    _ticker.dispose();
    videoController.removeListener(_onVideoUpdate);
    super.dispose();
  }
}
