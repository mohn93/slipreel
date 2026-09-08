import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/audio/music_transport.dart';

void main() {
  test(
    'ten minutes of continuous playback at each rate requires only the initial seek',
    () {
      for (final speed in [0.5, 1.0, 2.0]) {
        final transport = MusicTransport();
        var seeks = 0;
        for (var frame = 0; frame < 36000; frame++) {
          final now = Duration(microseconds: frame * 16667);
          final position = Duration(
            microseconds: (now.inMicroseconds * speed).round(),
          );
          if (transport.needsSeek(
            position: position,
            now: now,
            playing: true,
            speed: speed,
            seekRevision: 0,
          )) {
            seeks++;
          }
        }
        expect(seeks, 1, reason: 'Playback at $speed must not repeatedly seek');
      }
    },
  );
  test(
    'explicit small seeks, pause/resume and backward jumps still reposition',
    () {
      final transport = MusicTransport();
      bool tick(
        int milliseconds,
        int wall,
        bool playing, {
        int revision = 0,
        double speed = 1,
      }) => transport.needsSeek(
        position: Duration(milliseconds: milliseconds),
        now: Duration(milliseconds: wall),
        playing: playing,
        speed: speed,
        seekRevision: revision,
      );
      expect(tick(0, 0, true), isTrue);
      expect(tick(100, 100, true), isFalse);
      expect(tick(125, 110, true, revision: 1), isTrue);
      expect(tick(135, 120, true, revision: 1, speed: 2), isFalse);
      expect(tick(155, 130, true, revision: 1, speed: 2), isFalse);
      expect(tick(155, 140, false, revision: 1), isTrue);
      expect(tick(155, 150, false, revision: 1), isFalse);
      expect(tick(90, 160, false, revision: 2), isTrue);
      expect(tick(90, 170, true, revision: 2), isTrue);
      expect(tick(1000, 180, true, revision: 2), isTrue);
      expect(tick(100, 190, true, revision: 2), isTrue);
    },
  );
}
