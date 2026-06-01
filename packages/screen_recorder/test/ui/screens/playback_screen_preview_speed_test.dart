// Tests for the preview-playback-speed wiring on PlaybackScreen.
//
// Full PlaybackScreen widget tests require a valid video file and a
// live RecordingMetadata sidecar — none of which are available in the
// unit-test sandbox. Per project convention (see
// playback_screen_export_test.dart), we test the seams as pure helpers.
//
// Coverage:
//   - effectivePreviewRate: math is just `clipSpeed * previewSpeed`.
//   - shouldReapplyOnResume: only the false→true edge re-applies; the
//     critical case is pause→resume (Space-key or play-button), which
//     on macOS resets AVPlayer's rate to 1.0 — without re-applying the
//     dropdown selection would silently drop to 1× on every resume.

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/playback_screen.dart';

void main() {
  group('effectivePreviewRate', () {
    test('returns clipSpeed × previewSpeed', () {
      expect(effectivePreviewRate(1.0, 1.0), 1.0);
      expect(effectivePreviewRate(1.0, 4.0), 4.0);
      expect(effectivePreviewRate(2.0, 4.0), 8.0);
      expect(effectivePreviewRate(0.5, 8.0), 4.0);
    });
  });

  group('shouldReapplyOnResume', () {
    test('fires on the false→true edge (resume)', () {
      expect(shouldReapplyOnResume(prev: false, next: true), isTrue);
    });

    test('does not fire on the true→false edge (pause)', () {
      expect(shouldReapplyOnResume(prev: true, next: false), isFalse);
    });

    test('does not fire on same-state ticks (playing→playing)', () {
      expect(shouldReapplyOnResume(prev: true, next: true), isFalse);
    });

    test('does not fire on same-state ticks (paused→paused)', () {
      expect(shouldReapplyOnResume(prev: false, next: false), isFalse);
    });
  });

  group('preview speed persists across pause/resume (simulated)', () {
    // Simulates the on-screen flow: the user sets preview=4× while the
    // controller is at clipSpeed=1×, then pause/resume cycles through
    // the play-state listener. After each resume, the listener must
    // re-apply effectivePreviewRate so the controller's rate is 4.0,
    // not the post-play() default of 1.0.
    test('reset-to-1 by AVPlayer is corrected on the next resume', () {
      // Stand-in for VideoPlayerController.value.playbackSpeed.
      double controllerRate = 1.0;
      bool isPlaying = true;
      bool prevIsPlaying = true;

      const clipSpeed = 1.0;
      const previewSpeed = 4.0;

      // Initial apply (from the dropdown change).
      controllerRate = effectivePreviewRate(clipSpeed, previewSpeed);
      expect(controllerRate, 4.0);

      // User taps pause → controller emits isPlaying=false. Listener
      // sees true→false: no re-apply.
      isPlaying = false;
      if (shouldReapplyOnResume(prev: prevIsPlaying, next: isPlaying)) {
        controllerRate = effectivePreviewRate(clipSpeed, previewSpeed);
      }
      prevIsPlaying = isPlaying;
      expect(controllerRate, 4.0, reason: 'pause does not change the rate');

      // User taps Space → app calls controller.play(); AVPlayer
      // resets rate to 1.0; THEN emits isPlaying=true. Listener sees
      // false→true: re-apply.
      controllerRate = 1.0; // AVPlayer's silent reset.
      isPlaying = true;
      if (shouldReapplyOnResume(prev: prevIsPlaying, next: isPlaying)) {
        controllerRate = effectivePreviewRate(clipSpeed, previewSpeed);
      }
      prevIsPlaying = isPlaying;
      expect(controllerRate, 4.0,
          reason: 'resume re-applies the dropdown selection');
    });
  });
}
