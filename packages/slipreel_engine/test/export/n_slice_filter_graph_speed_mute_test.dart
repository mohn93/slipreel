import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/n_slice_filter_graph.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _stateWith(ClipSlice slice) =>
    EditorProjectState.defaults().copyWith(
      timeline: const Timeline(zoomTracks: []).copyWith(clips: [slice]),
    );

// A single mono source stream (one audio track → microphone role).
List<AudioStreamInfo> _oneStream() => const [
      AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
    ];

ClipSlice _slice(double speed) => ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(seconds: 10),
      playbackSpeed: speed,
    );

EditorProjectState _stateWithClips(List<ClipSlice> clips) =>
    EditorProjectState.defaults().copyWith(
      timeline: const Timeline(zoomTracks: []).copyWith(clips: clips),
    );

void main() {
  test('a slice sped past the threshold emits silent audio (volume=0) but '
      'keeps its atempo so the track duration stays aligned', () {
    final graph = buildExportFilterGraph(
      state: _stateWith(_slice(8.0)),
      audioStreams: _oneStream(),
    );
    expect(graph.filterComplex, contains('volume=0'));
    expect(graph.filterComplex, contains('atempo='),
        reason: 'the silent audio must still be sped up to match the video');
  });

  test('a slice at the threshold keeps full-gain audio', () {
    final graph = buildExportFilterGraph(
      state: _stateWith(_slice(4.0)),
      audioStreams: _oneStream(),
    );
    expect(graph.filterComplex, contains('volume=1.0'));
    expect(graph.filterComplex, isNot(contains('volume=0')));
  });

  test('in a multi-slice project only the >threshold slice is silenced, and '
      'every slice keeps its concat slot (A/V alignment)', () {
    // Slice 0 at 2× (audio kept), slice 1 at 8× (silenced). Both are sped up,
    // so both carry an atempo; the silenced slice must keep its atempo + concat
    // slot so the audio concat stays frame-aligned with the video concat.
    final graph = buildExportFilterGraph(
      state: _stateWithClips([_slice(2.0), _slice(8.0)]),
      audioStreams: _oneStream(),
    );
    expect(graph.filterComplex, contains('volume=1.0'),
        reason: 'the 2x slice keeps full-gain audio');
    expect(graph.filterComplex, contains('volume=0'),
        reason: 'the 8x slice is silenced');
    expect(graph.filterComplex, contains('atempo='),
        reason: 'the silenced slice keeps its atempo for duration alignment');
    expect(graph.filterComplex, contains('concat=n=2'),
        reason: 'both slices keep their concat slot — no dropped audio stream');
  });
}
