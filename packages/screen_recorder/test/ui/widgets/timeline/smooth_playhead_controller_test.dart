import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _DelayedSeekVideoPlatform extends VideoPlayerPlatform {
  final List<Completer<void>> seekCompleters = [];
  Duration? requestedSeek;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => 1;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 10),
      size: const Size(1920, 1080),
    ),
  );

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> seekTo(int playerId, Duration position) {
    requestedSeek = position;
    final completer = Completer<void>();
    seekCompleters.add(completer);
    return completer.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SmoothPlayheadController application seeks', () {
    late VideoPlayerPlatform previousPlatform;
    late _DelayedSeekVideoPlatform platform;
    late VideoPlayerController video;
    late SmoothPlayheadController smooth;

    setUp(() async {
      previousPlatform = VideoPlayerPlatform.instance;
      platform = _DelayedSeekVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      video = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/test.mp4'),
      );
      await video.initialize();
      video.value = video.value.copyWith(
        position: const Duration(seconds: 5),
        isPlaying: true,
      );
      smooth = SmoothPlayheadController(
        videoController: video,
        vsync: const TestVSync(),
      );
    });

    tearDown(() async {
      smooth.dispose();
      await video.dispose();
      VideoPlayerPlatform.instance = previousPlatform;
    });

    test(
      'nearby backward seek moves immediately while native seek waits',
      () async {
        // 500ms backward used to fall inside the normal playback-jitter filter,
        // so the actual player sought while the moving playhead looked inert.
        final seek = smooth.seekTo(const Duration(milliseconds: 4500));

        expect(platform.requestedSeek, const Duration(milliseconds: 4500));
        expect(smooth.position, const Duration(milliseconds: 4500));

        // AVPlayer can publish its old timestamp while decoding the target.
        // That report must not undo the responsive visual jump.
        video.value = video.value.copyWith(
          position: const Duration(milliseconds: 5050),
        );
        expect(smooth.position, const Duration(milliseconds: 4500));

        platform.seekCompleters.single.complete();
        await seek;
        expect(video.value.position, const Duration(milliseconds: 4500));
        expect(
          smooth.position.inMilliseconds,
          closeTo(const Duration(milliseconds: 4500).inMilliseconds, 20),
        );
      },
    );

    test('nearby forward seek is not filtered as small native drift', () async {
      final seek = smooth.seekTo(const Duration(milliseconds: 5200));

      expect(smooth.position, const Duration(milliseconds: 5200));
      video.value = video.value.copyWith(
        position: const Duration(milliseconds: 5050),
      );
      expect(smooth.position, const Duration(milliseconds: 5200));

      platform.seekCompleters.single.complete();
      await seek;
      expect(video.value.position, const Duration(milliseconds: 5200));
    });

    test('older seek completion cannot overwrite a newer click', () async {
      final first = smooth.seekTo(const Duration(milliseconds: 4500));
      final second = smooth.seekTo(const Duration(seconds: 7));
      expect(smooth.position, const Duration(seconds: 7));

      // The first native seek lands late. Its controller notification must be
      // ignored while the second click still owns the pending-seek latch.
      platform.seekCompleters.first.complete();
      await first;
      expect(video.value.position, const Duration(milliseconds: 4500));
      expect(smooth.position, const Duration(seconds: 7));

      platform.seekCompleters.last.complete();
      await second;
      expect(video.value.position, const Duration(seconds: 7));
      expect(
        smooth.position.inMilliseconds,
        closeTo(const Duration(seconds: 7).inMilliseconds, 20),
      );
    });
  });

  group('SmoothPlayheadController.rebaseBaseOnSpeedChange', () {
    // The boundary-jump audit (2026-06-03) tracked a visible "jump
    // then slow back" at slice seams to a stale `_basePosition` not
    // being rebased when `value.playbackSpeed` changed. A naive fix
    // rebased to `videoController.value.position` — but that lags by
    // up to one tick (~125–250ms), so the playhead snapped BACKWARD
    // by that much at the seam (a new jitter pattern). The contract
    // is: on rate change, rebase the extrapolator's anchor to the
    // current SMOOTHED position so only the slope changes, not the
    // y-intercept.
    test('returns the smoothed value as the new base (not v.position)', () {
      const smoothed = Duration(milliseconds: 5234);
      expect(
        SmoothPlayheadController.rebaseBaseOnSpeedChange(
          currentSmoothed: smoothed,
        ),
        smoothed,
      );
    });

    test('identity at zero (initial state)', () {
      expect(
        SmoothPlayheadController.rebaseBaseOnSpeedChange(
          currentSmoothed: Duration.zero,
        ),
        Duration.zero,
      );
    });

    test('preserves sub-millisecond precision', () {
      // Smoothed extrapolation uses microsecond-accurate math; rebasing
      // must not silently quantise to milliseconds.
      const smoothed = Duration(microseconds: 5234567);
      expect(
        SmoothPlayheadController.rebaseBaseOnSpeedChange(
          currentSmoothed: smoothed,
        ),
        smoothed,
      );
    });
  });

  group('SmoothPlayheadController.resolvePausedPosition', () {
    const duration = Duration(seconds: 10);

    test('returns position as-is when far from duration', () {
      // User pauses mid-clip — leave the playhead exactly where it is.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          const Duration(seconds: 5),
          duration,
        ),
        const Duration(seconds: 5),
      );
    });

    test('pins to duration when within end-of-clip tolerance (33ms)', () {
      // Typical 30fps last-frame timestamp is duration - 1/30s = -33ms.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration - const Duration(milliseconds: 33),
          duration,
        ),
        duration,
      );
    });

    test('pins to duration when within tolerance (16ms / 60fps)', () {
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration - const Duration(milliseconds: 16),
          duration,
        ),
        duration,
      );
    });

    test('does NOT pin when 100ms or more below duration', () {
      // Boundary: tolerance is "less than 100ms". 100ms exactly is
      // NOT pinned — caller likely paused intentionally.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration - const Duration(milliseconds: 100),
          duration,
        ),
        duration - const Duration(milliseconds: 100),
      );
    });

    test('clamps positions past duration to duration', () {
      // Defensive: extrapolation overshoot should never report past
      // duration even if a buggy native layer surfaces it.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          duration + const Duration(milliseconds: 50),
          duration,
        ),
        duration,
      );
    });

    test('returns position as-is when duration is zero (uninitialized)', () {
      // Don't pin anything before the controller knows the clip length.
      expect(
        SmoothPlayheadController.resolvePausedPosition(
          const Duration(seconds: 1),
          Duration.zero,
        ),
        const Duration(seconds: 1),
      );
    });
  });

  group('SmoothPlayheadController.snapForwardWouldAdvance', () {
    // The snapForward contract: a snap only advances when the target
    // is STRICTLY GREATER than the current smoothed value. Equality
    // and backward targets are no-ops. This is what makes it safe to
    // call from the per-frame skip listener — duplicate fires with
    // the same target (or stale targets behind us after the seek
    // landed) don't reset the extrapolator's anchor or re-trigger
    // backward-drift suppression.
    test('advances when target is strictly greater', () {
      expect(
        SmoothPlayheadController.snapForwardWouldAdvance(
          target: const Duration(seconds: 12),
          currentSmoothed: const Duration(seconds: 8),
        ),
        isTrue,
      );
    });

    test('no-op when target equals current smoothed', () {
      // Already there; advancing again would reset the suppress
      // threshold and re-enable backward-drift ignoring needlessly.
      expect(
        SmoothPlayheadController.snapForwardWouldAdvance(
          target: const Duration(seconds: 12),
          currentSmoothed: const Duration(seconds: 12),
        ),
        isFalse,
      );
    });

    test('no-op when target is behind current smoothed', () {
      // snapForward intentionally never moves the playhead backward.
      // A stale skip-listener fire after the seek has already landed
      // and smoothed has rebased past the target must not undo that
      // progress.
      expect(
        SmoothPlayheadController.snapForwardWouldAdvance(
          target: const Duration(seconds: 8),
          currentSmoothed: const Duration(seconds: 12),
        ),
        isFalse,
      );
    });

    test('preserves sub-millisecond precision in the comparison', () {
      // The snap target is the next slice's trimStart, stored in
      // microseconds. A 1µs difference must still register as advance.
      expect(
        SmoothPlayheadController.snapForwardWouldAdvance(
          target: const Duration(microseconds: 8_000_001),
          currentSmoothed: const Duration(microseconds: 8_000_000),
        ),
        isTrue,
      );
    });

    test('zero target is a no-op against any non-negative smoothed', () {
      // Defensive: callers shouldn't snap to zero, but if they do
      // the controller must not silently rewind to the start.
      expect(
        SmoothPlayheadController.snapForwardWouldAdvance(
          target: Duration.zero,
          currentSmoothed: const Duration(seconds: 5),
        ),
        isFalse,
      );
    });
  });

  group('SmoothPlayheadController.shouldClearBackwardDriftSuppression', () {
    // After snapForward, the suppress threshold is the seek target.
    // The player's reported v.position lags the seek by 50–200 ms;
    // while reports are still BELOW the threshold the seek hasn't
    // landed yet and treating them as drift would snap the smoothed
    // value backward into the trim gap. Suppression must clear the
    // INSTANT v.position catches up — keeping it on for one extra
    // frame would freeze the extrapolator at the snap target until
    // the next controller tick.
    const suppressBelow = Duration(seconds: 12);

    test('holds while v.position is below the threshold', () {
      expect(
        SmoothPlayheadController.shouldClearBackwardDriftSuppression(
          vPosition: const Duration(milliseconds: 8500),
          suppressBelow: suppressBelow,
        ),
        isFalse,
      );
    });

    test('clears at the exact threshold (seek just landed)', () {
      // Boundary: the seek's first valid v.position report can equal
      // the target exactly. Suppression must clear on equality so
      // drift handling resumes immediately and rebases the extrapolator.
      expect(
        SmoothPlayheadController.shouldClearBackwardDriftSuppression(
          vPosition: suppressBelow,
          suppressBelow: suppressBelow,
        ),
        isTrue,
      );
    });

    test('clears when v.position has moved past the threshold', () {
      expect(
        SmoothPlayheadController.shouldClearBackwardDriftSuppression(
          vPosition: const Duration(milliseconds: 12_050),
          suppressBelow: suppressBelow,
        ),
        isTrue,
      );
    });

    test('holds at one microsecond below the threshold', () {
      // Boundary check on the strict-inequality side — keeps the
      // contract symmetric with the equality-clears case above.
      expect(
        SmoothPlayheadController.shouldClearBackwardDriftSuppression(
          vPosition: suppressBelow - const Duration(microseconds: 1),
          suppressBelow: suppressBelow,
        ),
        isFalse,
      );
    });
  });
}
