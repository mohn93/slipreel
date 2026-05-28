import 'audio_streams.dart';
import '../state/audio_mix.dart';

/// AAC bitrate of the mixed export audio track.
const int kMixedAudioBitrateKbps = 192;

/// The ffmpeg audio plan for an export: an audio filtergraph producing
/// `[aout]`, the map label, and the target bitrate. All null when the export
/// has no audio (no streams, or every usable track muted / at 0%).
class AudioMixPlan {
  final String? filterComplex;
  final String? mapLabel;
  final int? bitrateKbps;
  const AudioMixPlan({this.filterComplex, this.mapLabel, this.bitrateKbps});

  bool get hasAudio => filterComplex != null && mapLabel != null;
}

class _Usable {
  final int index;
  final double fraction;
  const _Usable(this.index, this.fraction);
}

/// ffmpeg volume fraction, e.g. 1.0 / 1.5 / 0.5.
///
/// Formats to a stable, short string: fixed 3 decimals (so a gain percent
/// like 145 yields `1.450` instead of a long binary-float tail such as
/// `1.4500000000000002`), then strips trailing zeros while keeping at least
/// one digit after the point. ffmpeg's `volume=` accepts this plain decimal.
String _fracStr(double f) {
  var s = f.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s += '0';
  }
  return s;
}

/// Builds the export audio plan from probed [streams] and the editor [mix].
/// Input 1 (the recording) carries the audio streams.
AudioMixPlan buildAudioMixArgs(List<AudioStreamInfo> streams, AudioMix mix) {
  final roles = inferAudioRoles(streams);

  final usable = <_Usable>[];
  // Microphone first so its chain is [a0] in the 2-track case.
  if (roles.containsKey(AudioRole.microphone) &&
      !mix.micMuted &&
      mix.micGainPercent > 0) {
    usable.add(_Usable(roles[AudioRole.microphone]!, mix.micGainPercent / 100));
  }
  if (roles.containsKey(AudioRole.system) &&
      !mix.systemMuted &&
      mix.systemGainPercent > 0) {
    usable.add(_Usable(roles[AudioRole.system]!, mix.systemGainPercent / 100));
  }

  if (usable.isEmpty) {
    return const AudioMixPlan();
  }
  if (usable.length == 1) {
    final u = usable.single;
    return AudioMixPlan(
      filterComplex: '[1:a:${u.index}]volume=${_fracStr(u.fraction)},'
          'aformat=sample_rates=48000:channel_layouts=stereo[aout]',
      mapLabel: '[aout]',
      bitrateKbps: kMixedAudioBitrateKbps,
    );
  }
  final chains = <String>[];
  for (var i = 0; i < usable.length; i++) {
    final u = usable[i];
    chains.add('[1:a:${u.index}]volume=${_fracStr(u.fraction)},'
        'aformat=sample_rates=48000:channel_layouts=stereo[a$i]');
  }
  final mixInputs = List.generate(usable.length, (i) => '[a$i]').join();
  chains.add('${mixInputs}amix=inputs=${usable.length}:normalize=0[aout]');
  return AudioMixPlan(
    filterComplex: chains.join(';'),
    mapLabel: '[aout]',
    bitrateKbps: kMixedAudioBitrateKbps,
  );
}
