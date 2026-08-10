// packages/slipreel_engine/lib/export/n_slice_filter_graph.dart
//
// N-slice ffmpeg filter_complex builder.
//
// Today's MP4 / GIF pipelines read [state.timeline.clips.first] and apply that
// single slice's playback/fade/audio across the whole video — they predate the
// cut tool. This file produces the filter_complex string needed to honour an
// arbitrary slice list:
//
//   - one per-slice video chain   ([0:v]trim,setpts,fade,...[v_i])
//   - one concat=n=N joining the per-slice video chains into [outv]
//   - per-slice mic and system chains, each concat=n=N into [mic_track]/[sys_track]
//   - a final amix=inputs=2 of mic + system into [outa] when both are present
//
// The pipeline wiring that swaps the encoder's [-vf] chain for this
// [-filter_complex] graph lands alongside playback-skip + edited-time scrub
// (tasks 13-14); this file is the pure source of truth callers will reach
// for once that wiring is in place. Kept side-effect free so it can be
// exercised in unit tests without spawning ffmpeg.
//
// Behavioural notes:
//   - Each slice uses [trimStart, trimEnd] for the ffmpeg `trim=` node (NOT
//     cutStart/cutEnd). Trimmed-away regions never appear in the output.
//   - Per-slice setpts is `setpts=(PTS-STARTPTS)/speed` — the STARTPTS reset
//     is necessary so each chain's first frame lines up at concat time zero.
//   - Per-slice fades are slice-local: `fade=t=in:st=0:d=fadeIn` and
//     `fade=t=out:st=effectiveSec-fadeOut:d=fadeOut`. Each slice fades into
//     and out of itself independently.
//   - Muted slices keep their place in the chain with `volume=0` so the
//     concat input count stays equal to the slice count — dropping muted
//     slices would desync audio against the video concat.

import '../state/clip_slice.dart';
import '../state/editor_project_state.dart';
import 'audio_streams.dart';
import 'ffmpeg_filters.dart';

/// Concrete labels produced by [buildExportFilterGraph]: the
/// `-filter_complex` string and the `-map` targets the encoder should bind.
class NSliceFilterGraph {
  /// The full `-filter_complex` payload. Empty when [state.timeline.clips]
  /// is empty (no usable slices ⇒ no graph).
  final String filterComplex;

  /// Label to pass to `-map` for video. Null when [state.timeline.clips]
  /// is empty.
  final String? videoMapLabel;

  /// Label to pass to `-map` for the final mixed audio. Null when there are
  /// no usable audio streams (or no slices) — caller should skip `-c:a` and
  /// the audio `-map` in that case.
  final String? audioMapLabel;

  /// Number of slices the graph was built for. Equals the concat=n input count
  /// on every chain (video + per-track audio).
  final int sliceCount;

  const NSliceFilterGraph({
    required this.filterComplex,
    required this.videoMapLabel,
    required this.audioMapLabel,
    required this.sliceCount,
  });
}

/// Builds the N-slice `-filter_complex` payload for [state.timeline.clips].
///
/// [audioStreams] is the ffprobe result of the source MP4. Pass the empty
/// list to skip the audio half of the graph (video-only export).
///
/// [videoTimeOffset] is subtracted from video trim boundaries when the raw
/// frame decoder has already seeked into the source. Audio boundaries remain
/// absolute because audio is opened separately from the original movie.
///
/// Always produces a valid graph for N >= 1: a 1-slice project still uses
/// `concat=n=1`, which ffmpeg accepts as a no-op concat. Returns an empty
/// graph for N == 0.
NSliceFilterGraph buildExportFilterGraph({
  required EditorProjectState state,
  required List<AudioStreamInfo> audioStreams,
  Duration videoTimeOffset = Duration.zero,
}) {
  final clips = state.timeline.clips;
  if (clips.isEmpty) {
    return const NSliceFilterGraph(
      filterComplex: '',
      videoMapLabel: null,
      audioMapLabel: null,
      sliceCount: 0,
    );
  }

  final roles = inferAudioRoles(audioStreams);
  final micIdx = roles[AudioRole.microphone];
  final sysIdx = roles[AudioRole.system];

  final chains = <String>[];

  // Video: one chain per slice, then concat=n=N:v=1:a=0[outv].
  for (var i = 0; i < clips.length; i++) {
    chains.add(_videoChainFor(clips[i], i, timeOffset: videoTimeOffset));
  }
  chains.add(
    '${_labels('v', clips.length)}'
    'concat=n=${clips.length}:v=1:a=0[outv]',
  );

  // Audio: per-track per-slice chains, concat per track, then amix the two
  // tracks. Muted/0% slices still contribute volume=0 to keep concat input
  // counts aligned with video.
  final hasMic = micIdx != null;
  final hasSys = sysIdx != null;

  String? audioMapLabel;
  if (hasMic && hasSys) {
    // Both tracks: each concats into its own intermediate label so they can
    // be amixed at the end.
    chains.addAll(
      _trackChainBlock(
        clips: clips,
        streamLabel: '[1:a:$micIdx]',
        chainTag: 'a_mic',
        outLabel: '[mic_track]',
        gainOf: (c) => c.micGainPercent,
        mutedOf: (c) => c.micMuted,
        streamStartMicros: _startMicrosForIdx(audioStreams, micIdx),
      ),
    );
    chains.addAll(
      _trackChainBlock(
        clips: clips,
        streamLabel: '[1:a:$sysIdx]',
        chainTag: 'a_sys',
        outLabel: '[sys_track]',
        gainOf: (c) => c.systemGainPercent,
        mutedOf: (c) => c.systemMuted,
        streamStartMicros: _startMicrosForIdx(audioStreams, sysIdx),
      ),
    );
    chains.add('[mic_track][sys_track]amix=inputs=2:normalize=0[outa]');
    audioMapLabel = '[outa]';
  } else if (hasMic) {
    chains.addAll(
      _trackChainBlock(
        clips: clips,
        streamLabel: '[1:a:$micIdx]',
        chainTag: 'a_mic',
        outLabel: '[outa]',
        gainOf: (c) => c.micGainPercent,
        mutedOf: (c) => c.micMuted,
        streamStartMicros: _startMicrosForIdx(audioStreams, micIdx),
      ),
    );
    audioMapLabel = '[outa]';
  } else if (hasSys) {
    chains.addAll(
      _trackChainBlock(
        clips: clips,
        streamLabel: '[1:a:$sysIdx]',
        chainTag: 'a_sys',
        outLabel: '[outa]',
        gainOf: (c) => c.systemGainPercent,
        mutedOf: (c) => c.systemMuted,
        streamStartMicros: _startMicrosForIdx(audioStreams, sysIdx),
      ),
    );
    audioMapLabel = '[outa]';
  }

  return NSliceFilterGraph(
    filterComplex: chains.join(';'),
    videoMapLabel: '[outv]',
    audioMapLabel: audioMapLabel,
    sliceCount: clips.length,
  );
}

// "[v0][v1][v2]" etc.
String _labels(String tag, int n) {
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write('[$tag$i]');
  }
  return sb.toString();
}

/// Per-track block: one per-slice atrim/asetpts/atempo/volume/afade chain
/// for each slice, followed by a `concat=n=N:v=0:a=1` collapsing them all
/// into [outLabel]. The caller picks the labels (mic vs system) and the
/// gain/muted accessors; this function is otherwise track-agnostic.
List<String> _trackChainBlock({
  required List<ClipSlice> clips,
  required String streamLabel,
  required String chainTag,
  required String outLabel,
  required int Function(ClipSlice) gainOf,
  required bool Function(ClipSlice) mutedOf,
  required int streamStartMicros,
}) {
  final out = <String>[];
  for (var i = 0; i < clips.length; i++) {
    out.add(
      _audioChainFor(
        clips[i],
        i,
        streamLabel: streamLabel,
        chainTag: chainTag,
        gainPercent: gainOf(clips[i]),
        muted: mutedOf(clips[i]),
        streamStartMicros: streamStartMicros,
      ),
    );
  }
  out.add(
    '${_labels(chainTag, clips.length)}'
    'concat=n=${clips.length}:v=0:a=1$outLabel',
  );
  return out;
}

/// The `start_time` (in micros) of the audio-relative stream [audioIdx], or 0
/// when absent. Matches by [AudioStreamInfo.index] (the audio-relative position
/// the `[1:a:K]` filter labels use).
int _startMicrosForIdx(List<AudioStreamInfo> streams, int audioIdx) {
  for (final s in streams) {
    if (s.index == audioIdx) return s.startMicros;
  }
  return 0;
}

String _videoChainFor(ClipSlice s, int i, {required Duration timeOffset}) {
  final shiftedStart = s.trimStart - timeOffset;
  final shiftedEnd = s.trimEnd - timeOffset;
  final tsSec = ffSeconds(
    shiftedStart < Duration.zero ? Duration.zero : shiftedStart,
  );
  final teSec = ffSeconds(
    shiftedEnd < Duration.zero ? Duration.zero : shiftedEnd,
  );
  final filters = <String>[
    'trim=start=$tsSec:end=$teSec',
    // Reset STARTPTS so each chain's first frame is at t=0 going into concat.
    'setpts=PTS-STARTPTS',
  ];
  if (s.playbackSpeed != 1.0) {
    // Per-slice setpts factor: a 2× speed slice plays in half its trimmed
    // duration.
    filters.add('setpts=(PTS-STARTPTS)/${s.playbackSpeed}');
  }
  // Slice-local effective output duration drives fade-out positioning.
  final effectiveOutMicros =
      (s.effectiveLength.inMicroseconds / s.playbackSpeed).round();
  final effectiveOut = Duration(microseconds: effectiveOutMicros);
  if (s.fadeIn > Duration.zero) {
    filters.add(
      'fade=t=in:st=${ffSeconds(Duration.zero)}:d=${ffSeconds(s.fadeIn)}',
    );
  }
  if (s.fadeOut > Duration.zero) {
    final fadeOutStart = effectiveOut > s.fadeOut
        ? effectiveOut - s.fadeOut
        : Duration.zero;
    filters.add(
      'fade=t=out:st=${ffSeconds(fadeOutStart)}:d=${ffSeconds(s.fadeOut)}',
    );
  }
  return '[0:v]${filters.join(',')}[v$i]';
}

String _audioChainFor(
  ClipSlice s,
  int i, {
  required String streamLabel,
  required String chainTag,
  required int gainPercent,
  required bool muted,
  required int streamStartMicros,
}) {
  final tsSec = ffSeconds(s.trimStart);
  final teSec = ffSeconds(s.trimEnd);
  final filters = <String>[
    'atrim=start=$tsSec:end=$teSec',
    'asetpts=PTS-STARTPTS',
  ];
  if (s.playbackSpeed != 1.0) {
    filters.add(speedAtempo(s.playbackSpeed));
  }
  // volume=0 when the user muted the track OR the slice is sped past the
  // auto-mute threshold (audioSilencedBySpeed). The atempo above still runs so
  // the silent audio keeps the slice's sped-up duration and the per-track
  // concat stays aligned with the video concat.
  final volume = (muted || s.audioSilencedBySpeed) ? 0.0 : gainPercent / 100.0;
  filters.add('volume=${_volumeStr(volume)}');
  filters.add('aformat=sample_rates=48000:channel_layouts=stereo');
  final effectiveOutMicros =
      (s.effectiveLength.inMicroseconds / s.playbackSpeed).round();
  final effectiveOut = Duration(microseconds: effectiveOutMicros);
  // atrim + asetpts collapses a stream's leading no-packet gap. Restore that
  // silence inside EACH slice, after atempo, so its duration is expressed in
  // edited time. A single delay after concatenation is incorrect whenever the
  // slice is sped up/slowed down and cannot represent later slices that cross
  // the stream start independently.
  final missingSourceMicros = streamStartMicros - s.trimStart.inMicroseconds;
  final delayMicros = missingSourceMicros <= 0
      ? 0
      : (missingSourceMicros / s.playbackSpeed).round().clamp(
          0,
          effectiveOutMicros,
        );
  final delayMs = (delayMicros / 1000).round();
  if (delayMs > 0) filters.add('adelay=$delayMs:all=1');

  // Guarantee one audio segment with exactly the video's edited duration even
  // when this slice lies wholly before the stream's first packet or extends
  // past its last one. This keeps concat slots aligned across hard cuts.
  filters.add('apad=whole_dur=${ffSeconds(effectiveOut)}');
  filters.add('atrim=duration=${ffSeconds(effectiveOut)}');
  if (s.fadeIn > Duration.zero) {
    filters.add(
      'afade=t=in:st=${ffSeconds(Duration.zero)}:d=${ffSeconds(s.fadeIn)}',
    );
  }
  if (s.fadeOut > Duration.zero) {
    final fadeOutStart = effectiveOut > s.fadeOut
        ? effectiveOut - s.fadeOut
        : Duration.zero;
    filters.add(
      'afade=t=out:st=${ffSeconds(fadeOutStart)}:d=${ffSeconds(s.fadeOut)}',
    );
  }
  return '$streamLabel${filters.join(',')}[$chainTag$i]';
}

/// Stable, short ffmpeg `volume=` literal (mirrors `audio_mix_args.dart`).
String _volumeStr(double f) {
  var s = f.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s += '0';
  }
  return s;
}
