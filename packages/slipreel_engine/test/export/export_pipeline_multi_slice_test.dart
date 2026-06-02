// packages/slipreel_engine/test/export/export_pipeline_multi_slice_test.dart
//
// Pure unit tests for the N-slice ffmpeg filter_complex builder.
//
// The existing MP4 export pipeline still reads `clips.first` and routes a
// single slice's settings through FfmpegEncoder's -vf chain. Generalising
// the runtime decode/encode wiring to per-slice concat depends on the
// playback-skip work (tasks 13-14) which is the read side of the same
// edited-time model. This file commits to the BEHAVIOUR via a pure helper
// that runtime wiring can then adopt without ambiguity.

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/n_slice_filter_graph.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _stateWith(List<ClipSlice> clips) {
  final base = EditorProjectState.defaults();
  return base.copyWith(timeline: base.timeline.copyWith(clips: clips));
}

ClipSlice _slice({
  required int cs,
  required int ce,
  int? ts,
  int? te,
  double speed = 1.0,
  Duration fadeIn = Duration.zero,
  Duration fadeOut = Duration.zero,
  int micGainPercent = 100,
  bool micMuted = false,
  int systemGainPercent = 100,
  bool systemMuted = false,
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
      playbackSpeed: speed,
      fadeIn: fadeIn,
      fadeOut: fadeOut,
      micGainPercent: micGainPercent,
      micMuted: micMuted,
      systemGainPercent: systemGainPercent,
      systemMuted: systemMuted,
    );

// The shipping recording has two audio streams: mono mic (index 0) and
// stereo system (index 1). Mirrors what inferAudioRoles() returns for a
// real probe.
List<AudioStreamInfo> _twoTrackStreams() => const [
      AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
      AudioStreamInfo(index: 1, channels: 2, codecName: 'aac'),
    ];

void main() {
  group('buildExportFilterGraph — empty', () {
    test('empty slice list yields an empty graph and null map labels', () {
      final graph = buildExportFilterGraph(
        state: _stateWith(const []),
        audioStreams: _twoTrackStreams(),
      );
      expect(graph.filterComplex, isEmpty);
      expect(graph.videoMapLabel, isNull);
      expect(graph.audioMapLabel, isNull);
      expect(graph.sliceCount, 0);
    });
  });

  group('buildExportFilterGraph — N slices', () {
    test('single slice produces a single chain wrapped in concat=n=1', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([_slice(cs: 0, ce: 10)]),
        audioStreams: const [],
      );
      expect(graph.sliceCount, 1);
      expect(graph.filterComplex, contains('[v0]'));
      expect(graph.filterComplex, contains('concat=n=1:v=1:a=0[outv]'));
      expect(graph.videoMapLabel, '[outv]');
    });

    test('two slices produce two video chains and concat=n=2', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12),
        ]),
        audioStreams: const [],
      );
      expect(
        RegExp(r'trim=start=0\.000000:end=5\.000000').hasMatch(graph.filterComplex),
        isTrue,
        reason: 'first slice trim node',
      );
      expect(
        RegExp(r'trim=start=5\.000000:end=12\.000000')
            .hasMatch(graph.filterComplex),
        isTrue,
        reason: 'second slice trim node',
      );
      expect(graph.filterComplex, contains('[v0]'));
      expect(graph.filterComplex, contains('[v1]'));
      expect(graph.filterComplex, contains('[v0][v1]concat=n=2:v=1:a=0[outv]'));
    });

    test('three slices produce three chains and concat=n=3', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 3),
          _slice(cs: 3, ce: 7),
          _slice(cs: 7, ce: 12),
        ]),
        audioStreams: const [],
      );
      expect(graph.filterComplex, contains('[v0]'));
      expect(graph.filterComplex, contains('[v1]'));
      expect(graph.filterComplex, contains('[v2]'));
      expect(
        graph.filterComplex,
        contains('[v0][v1][v2]concat=n=3:v=1:a=0[outv]'),
      );
    });
  });

  group('buildExportFilterGraph — per-slice settings', () {
    test('per-slice speed drives each chain\'s setpts factor independently', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 5, speed: 2.0),
          _slice(cs: 5, ce: 12, speed: 0.5),
        ]),
        audioStreams: const [],
      );
      expect(graph.filterComplex, contains('setpts=(PTS-STARTPTS)/2.0'));
      expect(graph.filterComplex, contains('setpts=(PTS-STARTPTS)/0.5'));
    });

    test('speed=1.0 omits the speed setpts (just the STARTPTS reset)', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([_slice(cs: 0, ce: 5)]),
        audioStreams: const [],
      );
      expect(graph.filterComplex, contains('setpts=PTS-STARTPTS'));
      expect(graph.filterComplex, isNot(contains('(PTS-STARTPTS)/1.0')));
    });

    test('trim bounds drive trim=, NOT cut bounds', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([_slice(cs: 0, ce: 10, ts: 2, te: 8)]),
        audioStreams: const [],
      );
      expect(graph.filterComplex, contains('trim=start=2.000000:end=8.000000'));
      expect(
        graph.filterComplex,
        isNot(contains('trim=start=0.000000:end=10.000000')),
      );
    });

    test('per-slice fadeIn / fadeOut are slice-local', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          // 5s effective length, fadeIn 0.5s, fadeOut 0.5s ⇒ fade-out at 4.5s.
          _slice(
            cs: 0,
            ce: 5,
            fadeIn: const Duration(milliseconds: 500),
            fadeOut: const Duration(milliseconds: 500),
          ),
        ]),
        audioStreams: const [],
      );
      expect(graph.filterComplex, contains('fade=t=in:st=0.000000:d=0.500000'));
      expect(graph.filterComplex,
          contains('fade=t=out:st=4.500000:d=0.500000'));
    });

    test('per-slice fadeOut accounts for the slice\'s own speed', () {
      // 10s effective trimmed length, 2× speed ⇒ 5s slice-local output, so
      // a 0.5s fade-out starts at 4.5s, not at 9.5s.
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(
            cs: 0,
            ce: 10,
            speed: 2.0,
            fadeOut: const Duration(milliseconds: 500),
          ),
        ]),
        audioStreams: const [],
      );
      expect(graph.filterComplex,
          contains('fade=t=out:st=4.500000:d=0.500000'));
    });
  });

  group('buildExportFilterGraph — audio', () {
    test('two slices produce per-slice mic + system chains, concat per track, '
        'then amix=inputs=2 across mic+sys', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12),
        ]),
        audioStreams: _twoTrackStreams(),
      );
      // Per-slice mic chains
      expect(graph.filterComplex, contains('[1:a:0]'));
      expect(graph.filterComplex, contains('[a_mic0]'));
      expect(graph.filterComplex, contains('[a_mic1]'));
      // Per-slice system chains
      expect(graph.filterComplex, contains('[1:a:1]'));
      expect(graph.filterComplex, contains('[a_sys0]'));
      expect(graph.filterComplex, contains('[a_sys1]'));
      // Per-track concat preserves slice count
      expect(
        graph.filterComplex,
        contains('[a_mic0][a_mic1]concat=n=2:v=0:a=1[mic_track]'),
      );
      expect(
        graph.filterComplex,
        contains('[a_sys0][a_sys1]concat=n=2:v=0:a=1[sys_track]'),
      );
      // Final 2-track mix
      expect(
        graph.filterComplex,
        contains('[mic_track][sys_track]amix=inputs=2:normalize=0[outa]'),
      );
      expect(graph.audioMapLabel, '[outa]');
    });

    test('muted slice contributes volume=0 and stays in the concat — '
        'concat input count still equals slice count', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12, micMuted: true),
        ]),
        audioStreams: _twoTrackStreams(),
      );
      // Both mic chains still emitted
      expect(graph.filterComplex, contains('[a_mic0]'));
      expect(graph.filterComplex, contains('[a_mic1]'));
      // Second slice's mic chain pins volume=0
      expect(graph.filterComplex, contains('volume=0'));
      // Concat across slices stays at N=2, not 1
      expect(
        graph.filterComplex,
        contains('[a_mic0][a_mic1]concat=n=2:v=0:a=1[mic_track]'),
      );
    });

    test('per-slice mic gain percent shows up as volume=fraction', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 5, micGainPercent: 150),
          _slice(cs: 5, ce: 12, micGainPercent: 50),
        ]),
        audioStreams: _twoTrackStreams(),
      );
      expect(graph.filterComplex, contains('volume=1.5'));
      expect(graph.filterComplex, contains('volume=0.5'));
    });

    test('per-slice audio fadeIn/fadeOut emit afade=t=in / afade=t=out at '
        'slice-local times', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(
            cs: 0,
            ce: 5,
            fadeIn: const Duration(milliseconds: 500),
            fadeOut: const Duration(milliseconds: 500),
          ),
        ]),
        audioStreams: _twoTrackStreams(),
      );
      expect(graph.filterComplex, contains('afade=t=in:st=0.000000:d=0.500000'));
      expect(graph.filterComplex,
          contains('afade=t=out:st=4.500000:d=0.500000'));
    });

    test('no audio streams ⇒ no audio half, video-only graph', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12),
        ]),
        audioStreams: const [],
      );
      expect(graph.audioMapLabel, isNull);
      expect(graph.filterComplex, isNot(contains('amix')));
      expect(graph.filterComplex, isNot(contains('a_mic')));
      expect(graph.filterComplex, isNot(contains('a_sys')));
      // Video half still present.
      expect(graph.videoMapLabel, '[outv]');
      expect(graph.filterComplex, contains('concat=n=2:v=1:a=0[outv]'));
    });

    test('only a mic stream ⇒ single track concat into [outa], no amix', () {
      final graph = buildExportFilterGraph(
        state: _stateWith([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12),
        ]),
        audioStreams: const [
          AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
        ],
      );
      expect(graph.audioMapLabel, '[outa]');
      expect(graph.filterComplex, isNot(contains('amix')));
      expect(graph.filterComplex,
          contains('[a_mic0][a_mic1]concat=n=2:v=0:a=1[outa]'));
    });
  });
}
