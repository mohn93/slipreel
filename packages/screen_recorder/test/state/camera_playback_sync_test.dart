import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/camera_playback_sync.dart';

void main() {
  group('CameraPlaybackSync', () {
    test('desired camera position = main − offset, clamped to [0, camDur]', () {
      const dur = Duration(seconds: 10);
      expect(
        CameraPlaybackSync.desiredCameraPosition(
          mainPosition: const Duration(seconds: 2),
          offsetMicros: 200000,
          cameraDuration: dur,
        ),
        const Duration(milliseconds: 1800),
      );
    });

    test('clamps below zero and beyond camera duration', () {
      const dur = Duration(seconds: 5);
      expect(
        CameraPlaybackSync.desiredCameraPosition(
          mainPosition: const Duration(milliseconds: 100),
          offsetMicros: 500000,
          cameraDuration: dur,
        ),
        Duration.zero,
      );
      expect(
        CameraPlaybackSync.desiredCameraPosition(
          mainPosition: const Duration(seconds: 9),
          offsetMicros: 0,
          cameraDuration: dur,
        ),
        dur,
      );
    });

    test('shouldSeek only when drift exceeds threshold', () {
      expect(
        CameraPlaybackSync.shouldSeek(
          current: const Duration(seconds: 2),
          desired: const Duration(milliseconds: 2010),
          threshold: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
      expect(
        CameraPlaybackSync.shouldSeek(
          current: const Duration(seconds: 2),
          desired: const Duration(milliseconds: 2200),
          threshold: const Duration(milliseconds: 50),
        ),
        isTrue,
      );
    });

    test('shouldSeek is false at exactly the threshold (strict >)', () {
      expect(
        CameraPlaybackSync.shouldSeek(
          current: const Duration(seconds: 2),
          desired: const Duration(milliseconds: 2050),
          threshold: const Duration(milliseconds: 50),
        ),
        isFalse, // drift == 50ms, not > 50ms
      );
    });

    test('desiredCameraPosition handles a negative offset '
        '(camera started after the screen)', () {
      // offset -200ms => camera_time = main + 200ms.
      expect(
        CameraPlaybackSync.desiredCameraPosition(
          mainPosition: const Duration(seconds: 2),
          offsetMicros: -200000,
          cameraDuration: const Duration(seconds: 10),
        ),
        const Duration(milliseconds: 2200),
      );
    });
  });
}
