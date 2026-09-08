import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/music_graph.dart';
import 'package:slipreel_engine/audio/music_track.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/ffmpeg_encoder.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/export/n_slice_filter_graph.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  final ffmpeg = Ffmpeg.resolve();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('music-graph-test');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  final clips = [
    ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 4)),
  ];
  const streams = [
    AudioStreamInfo(index: 0, channels: 1, codecName: 'pcm_s16le'),
  ];
  const music = MusicTrack(
    path: 'unused',
    name: 'tone',
    sourceDuration: 1,
    start: 0.5,
    trimStart: 0.1,
    trimEnd: 0.9,
    fadeIn: 0.2,
    fadeOut: 0.3,
    volume: 1,
  );
  Future<List<double>> render(
    MusicTrack track, {
    List<ClipSlice>? slices,
  }) async {
    final graph = buildMusicGraph(
      track: track,
      duration: 4,
      clips: slices ?? clips,
      streams: streams,
      musicInput: 0,
      recordingInput: 1,
    );
    final result = await Process.run(ffmpeg, [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1:sample_rate=48000',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=120:duration=4:sample_rate=48000',
      '-filter_complex',
      graph,
      '-map',
      '[music]',
      '-f',
      'f32le',
      '-ac',
      '1',
      '-',
    ], stdoutEncoding: null);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$graph');
    final data = ByteData.sublistView(
      Uint8List.fromList(result.stdout as List<int>),
    );
    return List.generate(
      data.lengthInBytes ~/ 4,
      (i) => data.getFloat32(i * 4, Endian.little),
    );
  }

  double rms(List<double> samples, double start, double end) {
    final window = samples.sublist(
      (start * 48000).round(),
      (end * 48000).round(),
    );
    return sqrt(window.fold<double>(0, (v, x) => v + x * x) / window.length);
  }

  test(
    'real ffmpeg: crossfaded loop, delay, outer fades and exact duration',
    () async {
      final graph = buildMusicGraph(
        track: music,
        duration: 4,
        clips: clips,
        streams: streams,
        musicInput: 0,
        recordingInput: 1,
      );
      // The loop is built as an overlap-add `amix` of delayed, seam-faded
      // copies (see buildMusicGraph): no `acrossfade`, which is broken on the
      // bundled ffmpeg 7.x. The per-seam cross-fade windows must precede the
      // outer fade-in applied to the whole bed.
      expect(graph, contains('amix=inputs=5:normalize=0'));
      expect(graph, isNot(contains('acrossfade')));
      expect(graph, contains('afade=t=out:st=0.720000:d=0.080000:curve=tri'));
      expect(
        graph.indexOf('amix='),
        lessThan(graph.indexOf('afade=t=in:d=')),
      );
      final samples = await render(music);
      expect(samples.length, 192000);
      expect(rms(samples, 0, 0.49), 0);
      expect(rms(samples, 2, 3), greaterThan(0.04));
      expect(rms(samples, 3.97, 4), lessThan(rms(samples, 2, 3) * 0.1));

      // The first pass remains 0.8s and later circular cycles are 0.72s after
      // their 80ms overlap. Both boundaries meet without an abrupt sample jump.
      final unfaded = await render(music.copyWith(fadeIn: 0, fadeOut: 0));
      for (final time in [music.start + 0.8, music.start + 1.52]) {
        final seam = (time * 48000).round();
        expect((unfaded[seam] - unfaded[seam - 1]).abs(), lessThan(0.02));
      }

      final once = await render(music.copyWith(loop: false));
      expect(rms(once, 1.4, 3.9), 0);
      final muted = await render(music.copyWith(muted: true));
      expect(rms(muted, 0, 4), 0);
    },
  );
  test(
    'real ffmpeg: speech ducking respects muted and sped-up microphone clips',
    () async {
      final plain = await render(music);
      final ducked = await render(music.copyWith(duck: true));
      expect(rms(ducked, 2, 3), lessThan(rms(plain, 2, 3) * 0.7));
      final silentMic = await render(
        music.copyWith(duck: true),
        slices: [clips.first.copyWith(micMuted: true)],
      );
      expect(rms(silentMic, 2, 3), closeTo(rms(plain, 2, 3), 0.001));
      final cuts = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 2),
          playbackSpeed: 2,
        ),
        ClipSlice(
          cutStart: const Duration(seconds: 2),
          cutEnd: const Duration(seconds: 4),
          playbackSpeed: 2 / 3,
        ),
      ];
      expect(
        (await render(music.copyWith(duck: true), slices: cuts)).length,
        192000,
      );
    },
  );
  test(
    'real ffmpeg: a nine-second AAC selection keeps playing when looped',
    () async {
      final source = '${dir.path}/long.m4a';
      var result = await Process.run(ffmpeg, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=443:duration=40',
        '-c:a',
        'aac',
        source,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      const track = MusicTrack(
        path: 'unused',
        name: 'compressed',
        sourceDuration: 40,
        trimEnd: 9,
        fadeIn: 0.5,
        fadeOut: 1,
        volume: 1,
      );
      final graph = buildMusicGraph(
        track: track,
        duration: 30.866,
        clips: clips,
        streams: const [],
        musicInput: 0,
      );
      expect(graph, contains('asplit=4'));
      expect(graph, isNot(contains('concat=n=2')));
      expect(graph, isNot(contains('aloop=')));
      result = await Process.run(ffmpeg, [
        '-v',
        'error',
        '-i',
        source,
        '-filter_complex',
        graph,
        '-map',
        '[music]',
        '-f',
        'f32le',
        '-ac',
        '1',
        '-',
      ], stdoutEncoding: null);
      expect(result.exitCode, 0, reason: '${result.stderr}\n$graph');
      final bytes = Uint8List.fromList(result.stdout as List<int>);
      final data = ByteData.sublistView(bytes);
      final samples = List.generate(
        data.lengthInBytes ~/ 4,
        (i) => data.getFloat32(i * 4, Endian.little),
      );
      expect(samples.length, closeTo(30.866 * 48000, 2));
      expect(rms(samples, 4, 5), greaterThan(0.03));
      expect(rms(samples, 12, 13), greaterThan(0.03));
      expect(rms(samples, 24, 25), greaterThan(0.03));
    },
  );
  test(
    'real ffmpeg: video-only recording can export music and maintain input indexes',
    () async {
      final state = EditorProjectState.defaults().copyWith(
        timeline: Timeline(clips: clips, music: music),
      );
      final base = buildExportFilterGraph(state: state, audioStreams: []);
      final graph =
          '${base.filterComplex};${buildMusicGraph(track: music, duration: 4, clips: clips, streams: [])}';
      final args = FfmpegEncoder(
        outputPath: '${dir.path}/out.mp4',
        width: 16,
        height: 16,
        fps: 10,
        bitrateKbps: 100,
        audioSourcePath: 'video.mp4',
        musicSourcePath: 'music.wav',
        filterComplex: graph,
        videoOutLabel: '[outv]',
        audioOutLabel: '[music]',
      ).argsForTesting('libx264');
      expect(args.where((a) => a == '-i').length, 3);
      final result = await Process.run(ffmpeg, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=size=16x16:rate=10:duration=4',
        '-f',
        'lavfi',
        '-i',
        'color=size=16x16:rate=10:duration=4',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-filter_complex',
        graph,
        '-map',
        '[outv]',
        '-map',
        '[music]',
        '-f',
        'null',
        '-',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    },
  );
  test(
    'audio-only graph has no video inputs and can mix music with both recording tracks',
    () async {
      const both = [
        ...streams,
        AudioStreamInfo(index: 1, channels: 2, codecName: 'aac'),
      ];
      final state = EditorProjectState.defaults().copyWith(
        timeline: Timeline(clips: clips),
      );
      final base = buildExportFilterGraph(
        state: state,
        audioStreams: both,
        includeVideo: false,
      );
      expect(base.videoMapLabel, isNull);
      expect(base.filterComplex, isNot(contains('[0:v]')));
      final graph =
          '${base.filterComplex};${buildMusicGraph(track: music.copyWith(duck: true), duration: 4, clips: clips, streams: both, musicInput: 0)};[outa][music]amix=inputs=2:normalize=0[mix]';
      // One source file with a mono microphone and a stereo system track.
      final source = '${dir.path}/source.mkv';
      var result = await Process.run(ffmpeg, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=duration=4',
        '-f',
        'lavfi',
        '-i',
        'anullsrc=r=48000:cl=stereo',
        '-t',
        '4',
        '-map',
        '0:a',
        '-map',
        '1:a',
        '-c:a',
        'pcm_s16le',
        source,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      result = await Process.run(ffmpeg, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=duration=1',
        '-i',
        source,
        '-filter_complex',
        graph,
        '-map',
        '[mix]',
        '-f',
        'null',
        '-',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    },
  );
}
