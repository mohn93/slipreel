import '../export/audio_streams.dart';
import '../export/n_slice_filter_graph.dart';
import '../state/clip_slice.dart';
import 'music_track.dart';

/// Produces only the music bed; recording audio is mixed by the caller.
/// Shared by preview rendering and final export so envelopes and ducking agree.
String buildMusicGraph({
  required MusicTrack track,
  required double duration,
  required List<ClipSlice> clips,
  required List<AudioStreamInfo> streams,
  int musicInput = 2,
  int recordingInput = 1,
}) {
  String n(double v) => v.toStringAsFixed(6);
  final length = track.length(duration);
  final sourceFilters = <String>[
    'aresample=48000',
    'aformat=channel_layouts=stereo',
    'atrim=start=${n(track.trimStart)}:end=${n(track.end)}',
    'asetpts=PTS-STARTPTS',
  ];
  final outputFilters = <String>[
    // Rebuild a continuous sample clock after looping trimmed source frames.
    'asetpts=N/SR/TB',
    'atrim=duration=${n(length)}',
    'volume=${track.muted ? 0 : n(track.volume)}',
    if (track.fadeIn > 0) 'afade=t=in:d=${n(track.fadeIn.clamp(0, length))}',
    if (track.fadeOut > 0)
      'afade=t=out:st=${n((length - track.fadeOut).clamp(0, length))}:d=${n(track.fadeOut.clamp(0, length))}',
    'adelay=${(track.start * 48000).round()}S:all=1',
    // FFmpeg may emit the leading delay frames without PTS. Assign timestamps
    // before atrim, otherwise that silence is discarded by some versions.
    'asetpts=N/SR/TB',
    'apad=whole_dur=${n(duration)}',
    'atrim=duration=${n(duration)}',
  ];
  final mic = inferAudioRoles(streams)[AudioRole.microphone];
  final duck = track.duck && mic != null && clips.isNotEmpty;
  final outputLabel = duck ? 'music_raw' : 'music';
  final chains = <String>[];
  final repeats = track.loop && length > track.segmentDuration + (1 / 48000);
  if (repeats && track.segmentDuration > 0.02) {
    // Make enough finite copies to fill the bed, then overlap-add them with an
    // `amix`: each copy is delayed to its cycle offset and given a triangular
    // afade in/out over the seam so adjacent copies cross-fade where they
    // overlap. This deliberately avoids `acrossfade` fed from `asplit`, which
    // on ffmpeg 7.x (the bundled build) drains its first input to EOF and then
    // starves the sibling asplit branch, emitting only the first segment before
    // going silent. `asplit`+`amix` consume every branch in lockstep and behave
    // identically across ffmpeg 7 and 8.
    final crossfade = (track.segmentDuration * 0.1)
        .clamp(0.01, 0.25)
        .toDouble();
    final cycleDuration = track.segmentDuration - crossfade;
    final copyCount = ((length - crossfade) / cycleDuration).ceil();
    if (copyCount <= 64) {
      final labels = List.generate(copyCount, (i) => '[music_loop_$i]').join();
      chains.add(
        '[$musicInput:a:0]${sourceFilters.join(',')},asplit=$copyCount$labels',
      );
      final mixLabels = <String>[];
      for (var i = 0; i < copyCount; i++) {
        final offsetSamples = (i * cycleDuration * 48000).round();
        final branch = <String>[
          // Slide this copy to its cycle offset. asplit resets PTS to 0 on
          // every branch, so copy 0 keeps an explicit asetpts for parity.
          if (offsetSamples > 0)
            'adelay=${offsetSamples}S:all=1'
          else
            'asetpts=PTS-STARTPTS',
          // Fade the head in against the previous copy's tail (skipped on the
          // first copy) and the tail out against the next copy's head (skipped
          // on the last). Both sides of a seam share the same window.
          if (i > 0)
            'afade=t=in:st=${n(i * cycleDuration)}:d=${n(crossfade)}:curve=tri',
          if (i < copyCount - 1)
            'afade=t=out:st=${n((i + 1) * cycleDuration)}:d=${n(crossfade)}:curve=tri',
        ];
        chains.add('[music_loop_$i]${branch.join(',')}[music_xf_$i]');
        mixLabels.add('[music_xf_$i]');
      }
      chains.add(
        '${mixLabels.join()}amix=inputs=$copyCount:normalize=0:'
        'dropout_transition=0[music_looped]',
      );
      chains.add('[music_looped]${outputFilters.join(',')}[$outputLabel]');
    } else {
      // Very short selections can require hundreds of copies. Keep their graph
      // bounded and use the native loop rather than risking an unusable export.
      final filters = <String>[
        ...sourceFilters,
        'aloop=loop=-1:size=${(track.segmentDuration * 48000).round()}',
        ...outputFilters,
      ];
      chains.add('[$musicInput:a:0]${filters.join(',')}[$outputLabel]');
    }
  } else {
    final filters = <String>[
      ...sourceFilters,
      if (track.loop)
        'aloop=loop=-1:size=${(track.segmentDuration * 48000).round()}',
      ...outputFilters,
    ];
    chains.add('[$musicInput:a:0]${filters.join(',')}[$outputLabel]');
  }
  if (duck) {
    final stream = streams.firstWhere((s) => s.index == mic);
    for (var i = 0; i < clips.length; i++) {
      chains.add(
        buildSliceAudioChain(
          clips[i],
          i,
          streamLabel: '[$recordingInput:a:$mic]',
          chainTag: 'duck',
          gainPercent: clips[i].micGainPercent,
          muted: clips[i].micMuted,
          streamStartMicros: stream.startMicros,
        ),
      );
    }
    chains.add(
      '${List.generate(clips.length, (i) => '[duck$i]').join()}concat=n=${clips.length}:v=0:a=1[voice]',
    );
    chains.add(
      '[music_raw][voice]sidechaincompress=threshold=0.025:ratio=8:attack=20:release=400:makeup=1[music]',
    );
  }
  return chains.join(';');
}
