import 'dart:convert';

/// Which recording track a probed audio stream represents.
enum AudioRole { microphone, system }

/// One audio stream from an `ffprobe` of the recording.
class AudioStreamInfo {
  final int index;
  final int channels;
  final String codecName;
  final int? bitrateKbps;

  const AudioStreamInfo({
    required this.index,
    required this.channels,
    required this.codecName,
    this.bitrateKbps,
  });

  @override
  bool operator ==(Object other) =>
      other is AudioStreamInfo &&
      other.index == index &&
      other.channels == channels &&
      other.codecName == codecName &&
      other.bitrateKbps == bitrateKbps;

  @override
  int get hashCode => Object.hash(index, channels, codecName, bitrateKbps);
}

/// Parses the JSON output of
/// `ffprobe -select_streams a -show_entries stream=index,codec_name,channels,bit_rate -of json`.
List<AudioStreamInfo> parseAudioStreams(String jsonString) {
  if (jsonString.trim().isEmpty) return const [];
  final decoded = jsonDecode(jsonString);
  final streams = (decoded is Map && decoded['streams'] is List)
      ? decoded['streams'] as List
      : const [];
  return streams.indexed.map((entry) {
    final (audioIdx, s) = entry;
    final m = s as Map<String, dynamic>;
    final br = int.tryParse('${m['bit_rate'] ?? ''}');
    // Use the position in the audio-only list as the stream index so that
    // filter-complex references like `[1:a:0]` / `[1:a:1]` are correct.
    // ffprobe reports the absolute stream index (e.g. 1 for the second stream
    // overall), but ffmpeg's `-select_streams a` / `[N:a:K]` syntax expects
    // the audio-relative index K.
    return AudioStreamInfo(
      index: audioIdx,
      channels: (m['channels'] as num?)?.toInt() ?? 0,
      codecName: m['codec_name'] as String? ?? '',
      bitrateKbps: (br == null || br <= 0) ? null : (br / 1000).round(),
    );
  }).toList();
}

/// Maps audio streams to recording roles using this app's convention
/// (mic = mono, system = stereo). Falls back to stream order when channel
/// counts don't disambiguate.
Map<AudioRole, int> inferAudioRoles(List<AudioStreamInfo> streams) {
  if (streams.isEmpty) return const {};
  if (streams.length == 1) {
    final s = streams.first;
    return {s.channels >= 2 ? AudioRole.system : AudioRole.microphone: s.index};
  }
  final mono = streams.where((s) => s.channels <= 1).toList();
  final stereo = streams.where((s) => s.channels >= 2).toList();
  if (mono.isNotEmpty && stereo.isNotEmpty) {
    return {
      AudioRole.microphone: mono.first.index,
      AudioRole.system: stereo.first.index,
    };
  }
  // Channel counts didn't disambiguate; fall back to stream order
  // (streams[0] → mic, streams[1] → system). This app only ever produces
  // at most two audio tracks (mic + system), so >2 streams here is
  // unsupported and the role mapping becomes order-dependent — any extra
  // streams beyond the first two are silently ignored.
  assert(
    streams.length <= 2,
    'inferAudioRoles: >2 audio streams is unsupported and order-dependent '
    '(got ${streams.length}); only streams[0]/[1] are mapped.',
  );
  return {
    AudioRole.microphone: streams[0].index,
    AudioRole.system: streams[1].index,
  };
}
