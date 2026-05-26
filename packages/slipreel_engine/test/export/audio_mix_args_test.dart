import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_mix_args.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/state/audio_mix.dart';

void main() {
  AudioStreamInfo s(int i, int ch) =>
      AudioStreamInfo(index: i, channels: ch, codecName: 'aac');

  test('no streams => no audio', () {
    final p = buildAudioMixArgs(const [], const AudioMix());
    expect(p.filterComplex, isNull);
    expect(p.mapLabel, isNull);
    expect(p.bitrateKbps, isNull);
  });

  test('single mic track at 100%', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix());
    expect(p.filterComplex,
        '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]');
    expect(p.mapLabel, '[aout]');
    expect(p.bitrateKbps, 192);
  });

  test('single track muted => no audio', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix(micMuted: true));
    expect(p.filterComplex, isNull);
    expect(p.mapLabel, isNull);
  });

  test('single track at 0% => no audio', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix(micGainPercent: 0));
    expect(p.filterComplex, isNull);
  });

  test('two tracks both 100% => amix normalize=0', () {
    final p = buildAudioMixArgs([s(0, 1), s(1, 2)], const AudioMix());
    expect(p.filterComplex,
        '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[a0];'
        '[1:a:1]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[a1];'
        '[a0][a1]amix=inputs=2:normalize=0[aout]');
    expect(p.mapLabel, '[aout]');
    expect(p.bitrateKbps, 192);
  });

  test('two tracks, system muted => single mic chain', () {
    final p = buildAudioMixArgs(
        [s(0, 1), s(1, 2)], const AudioMix(systemMuted: true));
    expect(p.filterComplex,
        '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]');
    expect(p.mapLabel, '[aout]');
  });

  test('both muted => no audio', () {
    final p = buildAudioMixArgs([s(0, 1), s(1, 2)],
        const AudioMix(micMuted: true, systemMuted: true));
    expect(p.filterComplex, isNull);
  });

  test('boost 200% => volume=2.0', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix(micGainPercent: 200));
    expect(p.filterComplex, contains('volume=2.0'));
  });
}
