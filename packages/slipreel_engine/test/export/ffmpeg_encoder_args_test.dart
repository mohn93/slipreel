import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_encoder.dart';

void main() {
  group('plain-scale mode (no filter_complex)', () {
    test(
      'no filter_complex => no audio input/map/codec, no -filter_complex',
      () {
        final enc = FfmpegEncoder(
          outputPath: '/tmp/o.mp4',
          width: 100,
          height: 100,
          fps: 30,
          bitrateKbps: 2000,
        );
        final args = enc.argsForTesting('libx264');
        expect(args.contains('-c:a'), isFalse);
        expect(args.contains('-filter_complex'), isFalse);
      },
    );

    test('plain-scale: output != source dims => -vf scale,pad,setsar', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4',
        width: 200,
        height: 200,
        fps: 30,
        bitrateKbps: 2000,
        sourceWidth: 100,
        sourceHeight: 100,
      );
      final args = enc.argsForTesting('libx264');
      expect(args.contains('-vf'), isTrue);
      expect(args.contains('-filter_complex'), isFalse);
      expect(args.contains('-c:a'), isFalse);
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, contains('scale=200:200'));
      expect(vf, contains('pad='));
      expect(vf, contains('setsar=1'));
    });
  });

  group('filter-graph mode (used by ExportPipeline)', () {
    test('filter_complex + videoOutLabel only => video-only, no audio map', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4',
        width: 100,
        height: 100,
        fps: 30,
        bitrateKbps: 2000,
        filterComplex:
            '[0:v]trim=start=0.000000:end=5.000000,setpts=PTS-STARTPTS[v0];'
            '[v0]concat=n=1:v=1:a=0[outv]',
        videoOutLabel: '[outv]',
      );
      final args = enc.argsForTesting('libx264');
      final joined = args.join(' ');
      expect(joined, contains('-filter_complex'));
      expect(joined, contains('-map [outv]'));
      expect(args.contains('-c:a'), isFalse);
      expect(args.contains('-vf'), isFalse);
    });

    test(
      'filter_complex + audioOutLabel + audioSourcePath => audio input + map + aac',
      () {
        final enc = FfmpegEncoder(
          outputPath: '/tmp/o.mp4',
          width: 100,
          height: 100,
          fps: 30,
          bitrateKbps: 2000,
          audioSourcePath: '/tmp/in.mp4',
          filterComplex: '[0:v]null[outv];[1:a:0]volume=1[outa]',
          videoOutLabel: '[outv]',
          audioOutLabel: '[outa]',
        );
        final args = enc.argsForTesting('libx264');
        final joined = args.join(' ');
        expect(joined, contains('-i /tmp/in.mp4'));
        expect(joined, contains('-filter_complex'));
        expect(joined, contains('-map [outv]'));
        expect(joined, contains('-map [outa]'));
        expect(joined, contains('-c:a aac'));
        expect(joined, contains('-b:a 192k'));
        expect(args.contains('-vf'), isFalse);
      },
    );

    test(
      'filter_complex with audioOutLabel but no audioSourcePath => '
      'no -i audio, no audio map (caller protected from impossible config)',
      () {
        final enc = FfmpegEncoder(
          outputPath: '/tmp/o.mp4',
          width: 100,
          height: 100,
          fps: 30,
          bitrateKbps: 2000,
          filterComplex: '[0:v]null[outv]',
          videoOutLabel: '[outv]',
          audioOutLabel: '[outa]',
          // audioSourcePath omitted on purpose
        );
        final args = enc.argsForTesting('libx264');
        final joined = args.join(' ');
        // Only one -i (stdin); no second -i for audio.
        expect('-i '.allMatches(joined).length, 1);
        expect(args.contains('-c:a'), isFalse);
      },
    );

    test('audioBitrateKbps override is respected', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4',
        width: 100,
        height: 100,
        fps: 30,
        bitrateKbps: 2000,
        audioSourcePath: '/tmp/in.mp4',
        filterComplex: '[0:v]null[outv];[1:a:0]anull[outa]',
        videoOutLabel: '[outv]',
        audioOutLabel: '[outa]',
        audioBitrateKbps: 128,
      );
      final args = enc.argsForTesting('libx264');
      expect(args.join(' '), contains('-b:a 128k'));
    });
  });

  group('codec tuning flags', () {
    FfmpegEncoder enc() => FfmpegEncoder(
      outputPath: '/tmp/o.mp4',
      width: 100,
      height: 100,
      fps: 30,
      bitrateKbps: 2000,
    );

    test('libx264 fallback uses -preset veryfast', () {
      // Without an explicit preset x264 defaults to `medium`, which is
      // several times slower — and the software path only runs when the
      // HW encoder is unavailable, i.e. exactly when speed matters most.
      final args = enc().argsForTesting('libx264').join(' ');
      expect(args, contains('-preset veryfast'));
    });

    test('h264_videotoolbox gets no -preset (unsupported by the encoder)', () {
      final args = enc().argsForTesting('h264_videotoolbox').join(' ');
      expect(args, isNot(contains('-preset')));
    });

    test('both codecs write faststart MP4s (moov atom up front)', () {
      for (final codec in ['libx264', 'h264_videotoolbox']) {
        final args = enc().argsForTesting(codec).join(' ');
        expect(
          args,
          contains('-movflags +faststart'),
          reason:
              '$codec output should start playing before a full '
              'download (shareable-link streaming)',
        );
      }
    });
  });
}
