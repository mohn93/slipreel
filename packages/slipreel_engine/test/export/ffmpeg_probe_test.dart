// packages/screen_recorder/test/export/ffmpeg_probe_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';

void main() {
  group('ffmpegProbe', () {
    test('probes the test fixture and returns sane width/height/fps', () async {
      final result = await ffmpegProbe(
        path: 'test/fixtures/sample_recording.mp4',
      );

      expect(result.width, greaterThan(0),
          reason: 'width must be positive');
      expect(result.height, greaterThan(0),
          reason: 'height must be positive');
      expect(result.fps, greaterThan(0),
          reason: 'fps must be positive');

      // The fixture is a 320×240 recording.
      expect(result.width, equals(320));
      expect(result.height, equals(240));
    });

    test('includes nb_frames and duration from the test fixture', () async {
      final result = await ffmpegProbe(
        path: 'test/fixtures/sample_recording.mp4',
      );

      // The fixture is a ~1-second recording, so nb_frames and duration
      // should both be present and sane.
      expect(result.nbFrames, isNotNull,
          reason: 'fixture should have nb_frames in its container');
      expect(result.nbFrames, greaterThan(0));

      expect(result.durationSec, isNotNull,
          reason: 'fixture should have duration metadata');
      expect(result.durationSec, greaterThan(0.0));
      expect(result.durationSec, lessThan(10.0),
          reason: 'fixture is a short 1-second clip');
    });

    test('throws on a non-existent path', () async {
      await expectLater(
        () => ffmpegProbe(path: '/no/such/file/absolutely_does_not_exist.mp4'),
        throwsA(isA<Exception>()),
      );
    });

    test('uses metadataFps as fallback when source lacks frame rate', () async {
      // Feed a real file but verify that passing metadataFps does not
      // override the authoritative avg_frame_rate when the file has one.
      // The returned fps should match the file's actual rate, not the
      // (deliberately wrong) metadataFps we supply.
      final withMeta = await ffmpegProbe(
        path: 'test/fixtures/sample_recording.mp4',
        metadataFps: 1, // deliberately wrong
      );
      final withoutMeta = await ffmpegProbe(
        path: 'test/fixtures/sample_recording.mp4',
      );

      // avg_frame_rate is authoritative and should win over metadataFps.
      expect(withMeta.fps, equals(withoutMeta.fps),
          reason: 'metadataFps must not override avg_frame_rate');
    });
  });
}
