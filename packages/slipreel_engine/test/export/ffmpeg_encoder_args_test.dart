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
  });
}
