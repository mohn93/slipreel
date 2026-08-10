// packages/screen_recorder/test/export/ffmpeg_probe_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';

void main() {
  group('ffmpegProbe', () {
    setUp(clearFfmpegProbeCache);

    test('probes the test fixture and returns sane width/height/fps', () async {
      final result = await ffmpegProbe(
        path: 'test/fixtures/sample_recording.mp4',
      );

      expect(result.width, greaterThan(0), reason: 'width must be positive');
      expect(result.height, greaterThan(0), reason: 'height must be positive');
      expect(result.fps, greaterThan(0), reason: 'fps must be positive');

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
      expect(
        result.nbFrames,
        isNotNull,
        reason: 'fixture should have nb_frames in its container',
      );
      expect(result.nbFrames, greaterThan(0));

      expect(
        result.durationSec,
        isNotNull,
        reason: 'fixture should have duration metadata',
      );
      expect(result.durationSec, greaterThan(0.0));
      expect(
        result.durationSec,
        lessThan(10.0),
        reason: 'fixture is a short 1-second clip',
      );
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
      expect(
        withMeta.fps,
        equals(withoutMeta.fps),
        reason: 'metadataFps must not override avg_frame_rate',
      );
    });

    test(
      'memoizes by file identity and invalidates when mtime changes',
      () async {
        final tmp = Directory.systemTemp.createTempSync('ffprobe_cache');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final copy = await File(
          'test/fixtures/sample_recording.mp4',
        ).copy('${tmp.path}/sample.mp4');

        final first = await ffmpegProbe(path: copy.path);
        final cached = await ffmpegProbe(path: copy.path);
        expect(
          identical(first, cached),
          isTrue,
          reason: 'a stable file should reuse the completed probe result',
        );

        final oldMtime = (await copy.stat()).modified;
        await copy.setLastModified(oldMtime.add(const Duration(seconds: 1)));
        final invalidated = await ffmpegProbe(path: copy.path);
        expect(
          identical(first, invalidated),
          isFalse,
          reason: 'mtime is part of the cache key',
        );
        expect(invalidated.width, first.width);
      },
    );

    test('result defensively freezes audio stream metadata', () {
      final callerOwned = <AudioStreamInfo>[
        const AudioStreamInfo(
          index: 0,
          channels: 2,
          codecName: 'aac',
          startMicros: 0,
        ),
      ];
      final result = FfmpegProbeResult(
        width: 320,
        height: 240,
        fps: 30,
        audioStreams: callerOwned,
      );

      callerOwned.clear();
      expect(result.audioStreams, hasLength(1));
      expect(() => result.audioStreams.clear(), throwsUnsupportedError);
    });
  });
}
