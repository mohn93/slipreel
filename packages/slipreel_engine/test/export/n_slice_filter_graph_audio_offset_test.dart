import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/n_slice_filter_graph.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

// The export collapses each audio track's PTS to zero (atrim + asetpts), which
// drops the recording's audio leading-gap and shifts audio earlier than video.
// buildExportFilterGraph must re-add that gap with a per-track adelay so the
// exported audio lands back on movie-time (matching the in-sync preview).

EditorProjectState _stateWith(List<ClipSlice> clips) =>
    EditorProjectState.defaults().copyWith(
      timeline: const Timeline(zoomTracks: []).copyWith(clips: clips),
    );

ClipSlice _slice({Duration? trimStart}) => ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(seconds: 10),
      trimStart: trimStart,
    );

AudioStreamInfo _sys(int startMicros) => AudioStreamInfo(
      index: 0,
      channels: 2,
      codecName: 'aac',
      startMicros: startMicros,
    );

void main() {
  test('a system track with a 240ms leading gap gets adelay=240:all=1', () {
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [_sys(240000)],
    );
    expect(graph.filterComplex, contains('adelay=240:all=1'));
    expect(graph.audioMapLabel, '[outa]');
  });

  test('no leading gap (startMicros=0) emits no adelay', () {
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [_sys(0)],
    );
    expect(graph.filterComplex, isNot(contains('adelay')));
  });

  test('mic and system tracks each get their own adelay before amix', () {
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [
        const AudioStreamInfo(
            index: 0, channels: 1, codecName: 'aac', startMicros: 200000),
        const AudioStreamInfo(
            index: 1, channels: 2, codecName: 'aac', startMicros: 240000),
      ],
    );
    expect(graph.filterComplex, contains('adelay=200:all=1'));
    expect(graph.filterComplex, contains('adelay=240:all=1'));
    expect(graph.filterComplex, contains('amix=inputs=2'));
  });

  test('a first slice trimmed past the gap needs no adelay (already aligned)',
      () {
    // First slice starts at movie 1.0s, well past the 240ms gap → the audio
    // content is fully present, no collapse, delay clamps to 0.
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice(trimStart: const Duration(seconds: 1))]),
      audioStreams: [_sys(240000)],
    );
    expect(graph.filterComplex, isNot(contains('adelay')));
  });

  test('adelay is the gap MINUS the first slice trimStart', () {
    // gap 500ms, first slice trimmed to 100ms in → 400ms residual delay.
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice(trimStart: const Duration(milliseconds: 100))]),
      audioStreams: [_sys(500000)],
    );
    expect(graph.filterComplex, contains('adelay=400:all=1'));
  });

  test('multi-slice: the whole concatenated track is delayed exactly ONCE '
      '(mid-slices need no separate adelay)', () {
    // The per-slice atrim+asetpts+concat shifts the WHOLE track early by the
    // head-of-timeline gap, so a single track-level adelay restores it — not
    // one per slice. A regression that delayed per-slice would show 3 adelays.
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice(), _slice(), _slice()]),
      audioStreams: [_sys(240000)],
    );
    expect('adelay'.allMatches(graph.filterComplex).length, 1,
        reason: 'one adelay on the concatenated track, not per-slice');
    expect(graph.filterComplex, contains('adelay=240:all=1'));
    expect(graph.filterComplex, contains('concat=n=3'),
        reason: 'all 3 slices keep their concat slot');
  });

  // --- Exact wiring + edge cases ---

  test('single track: the adelay is wired concat → adelay → [outa]', () {
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [_sys(240000)],
    );
    // concat lands in an intermediate label, which adelay then maps to [outa].
    expect(graph.filterComplex, contains('concat=n=1:v=0:a=1[a_sys_cat]'));
    expect(graph.filterComplex, contains('[a_sys_cat]adelay=240:all=1[outa]'));
  });

  test('two tracks: each adelay feeds its track label, which feed the amix', () {
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [
        const AudioStreamInfo(
            index: 0, channels: 1, codecName: 'aac', startMicros: 200000),
        const AudioStreamInfo(
            index: 1, channels: 2, codecName: 'aac', startMicros: 240000),
      ],
    );
    expect(graph.filterComplex,
        contains('[a_mic_cat]adelay=200:all=1[mic_track]'));
    expect(graph.filterComplex,
        contains('[a_sys_cat]adelay=240:all=1[sys_track]'));
    expect(graph.filterComplex,
        contains('[mic_track][sys_track]amix=inputs=2:normalize=0[outa]'));
  });

  test('two tracks with asymmetric gaps: only the gapped track is delayed', () {
    // mic starts at t=0 (no gap → concats straight to its track, no adelay);
    // system has a 240ms gap → adelay. Each track is compensated independently.
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [
        const AudioStreamInfo(
            index: 0, channels: 1, codecName: 'aac', startMicros: 0),
        const AudioStreamInfo(
            index: 1, channels: 2, codecName: 'aac', startMicros: 240000),
      ],
    );
    expect(graph.filterComplex, contains('concat=n=1:v=0:a=1[mic_track]'),
        reason: 'no-gap mic concats straight to its track, no adelay');
    expect(graph.filterComplex, isNot(contains('a_mic_cat')),
        reason: 'no intermediate/adelay stage for the gapless track');
    expect(graph.filterComplex,
        contains('[a_sys_cat]adelay=240:all=1[sys_track]'));
    expect(graph.filterComplex, contains('amix=inputs=2'));
  });

  test('a sub-millisecond gap rounds to 0 → no adelay (never emits adelay=0)',
      () {
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [_sys(400)], // 0.4ms → rounds to 0ms
    );
    expect(graph.filterComplex, isNot(contains('adelay')));
    expect(graph.audioMapLabel, '[outa]', reason: 'audio still mapped');
  });

  test('the gap rounds to the nearest whole millisecond', () {
    final graph = buildExportFilterGraph(
      state: _stateWith([_slice()]),
      audioStreams: [_sys(1600)], // 1.6ms → rounds to 2ms
    );
    expect(graph.filterComplex, contains('adelay=2:all=1'));
  });

  test('adelay coexists with a sped-up slice without disturbing its atempo', () {
    final graph = buildExportFilterGraph(
      state: _stateWith([
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 10),
          playbackSpeed: 2.0,
        ),
      ]),
      audioStreams: [_sys(240000)],
    );
    expect(graph.filterComplex, contains('atempo='),
        reason: 'per-slice speed handling is untouched by the track-level delay');
    expect(graph.filterComplex, contains('adelay=240:all=1'));
  });
}
