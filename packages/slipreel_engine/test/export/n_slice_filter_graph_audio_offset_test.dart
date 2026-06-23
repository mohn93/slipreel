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
}
