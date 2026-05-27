import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_mix_args.dart';
import 'package:slipreel_engine/export/ffmpeg_encoder.dart';

void main() {
  test('no audio plan => no audio input/map/codec', () {
    final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
        bitrateKbps: 2000);
    final args = enc.argsForTesting('libx264');
    expect(args.contains('-c:a'), isFalse);
    expect(args.contains('-filter_complex'), isFalse);
  });

  test('audio plan => filter_complex + aac', () {
    final enc = FfmpegEncoder(
      outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
      bitrateKbps: 2000,
      audioSourcePath: '/tmp/in.mp4',
      audioMixPlan: const AudioMixPlan(
        filterComplex:
            '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]',
        mapLabel: '[aout]',
        bitrateKbps: 192,
      ),
    );
    final args = enc.argsForTesting('libx264');
    final joined = args.join(' ');
    expect(joined, contains('-i /tmp/in.mp4'));
    expect(joined, contains('-filter_complex'));
    expect(joined, contains('[aout]'));
    expect(joined, contains('-map [aout]'));
    expect(joined, contains('-c:a aac'));
    expect(joined, contains('-b:a 192k'));
    expect(args.contains('copy'), isFalse);
    expect(joined, contains('-map [vout]'));
    expect(args.contains('-vf'), isFalse); // video routed through filter_complex
  });

  test('video-only with scaling uses -vf (no filter_complex)', () {
    final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 200, height: 200, fps: 30,
        bitrateKbps: 2000, sourceWidth: 100, sourceHeight: 100);
    final args = enc.argsForTesting('libx264');
    expect(args.contains('-vf'), isTrue);
    expect(args.contains('-filter_complex'), isFalse);
    expect(args.contains('-c:a'), isFalse);
  });

  group('speed + fade filters', () {
    test('video-only: speed inserts setpts, fades insert fade in/out', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
        bitrateKbps: 2000,
        playbackSpeed: 2.0,
        fadeIn: const Duration(milliseconds: 500),
        fadeOut: const Duration(milliseconds: 500),
        outputDuration: const Duration(seconds: 5),
      );
      final args = enc.argsForTesting('libx264');
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, contains('setpts=PTS/2.0'));
      expect(vf, contains('fade=t=in:st=0:d=0.500000'));
      expect(vf, contains('fade=t=out:st=4.500000:d=0.500000'));
    });

    test('no speed / no fade => no setpts/fade in video chain', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 200, height: 200, fps: 30,
        bitrateKbps: 2000, sourceWidth: 100, sourceHeight: 100);
      final args = enc.argsForTesting('libx264');
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, isNot(contains('setpts')));
      expect(vf, isNot(contains('fade=')));
    });

    test('audio present: speed adds atempo, fade adds afade after the mix', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
        bitrateKbps: 2000,
        audioSourcePath: '/tmp/in.mp4',
        audioMixPlan: const AudioMixPlan(
          filterComplex:
              '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]',
          mapLabel: '[aout]',
          bitrateKbps: 192,
        ),
        playbackSpeed: 2.0,
        fadeIn: const Duration(milliseconds: 500),
        fadeOut: const Duration(milliseconds: 500),
        outputDuration: const Duration(seconds: 5),
      );
      final joined = enc.argsForTesting('libx264').join(' ');
      expect(joined, contains('atempo=2.0'));
      expect(joined, contains('afade=t=in:st=0:d=0.500000'));
      expect(joined, contains('afade=t=out:st=4.500000:d=0.500000'));
      // audio is remapped to the post-processed label, not the raw [aout]
      expect(joined, contains('-map [aoutx]'));
    });

    test('fadeOut longer than output clamps fade-out start to 0', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
        bitrateKbps: 2000,
        audioSourcePath: '/tmp/in.mp4',
        audioMixPlan: const AudioMixPlan(
          filterComplex:
              '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]',
          mapLabel: '[aout]',
          bitrateKbps: 192,
        ),
        fadeOut: const Duration(seconds: 2),
        outputDuration: const Duration(milliseconds: 500),
      );
      final args = enc.argsForTesting('libx264');
      final joined = args.join(' ');
      // Output is shorter than the fade — start must clamp to 0, not negative.
      expect(joined, contains('fade=t=out:st=0.000000:d=2.000000'));
      expect(joined, contains('afade=t=out:st=0.000000:d=2.000000'));
      expect(joined, isNot(contains('st=-')));
    });
  });
}
