// packages/slipreel_engine/test/export/gif_export_pipeline_multi_slice_test.dart
//
// Substring tests for the GIF pass-1 / pass-2 filter_complex builders.
//
// The GIF pipeline reuses `n_slice_filter_graph.dart` (with `audioStreams: []`
// for the no-audio video-only graph) and wraps `[outv]` with palette stages.
// These tests verify the per-slice + concat shape reaches the ffmpeg
// command line — analog of the MP4 multi-slice substring tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/export/n_slice_filter_graph.dart';
import 'package:slipreel_engine/models/compression_bitrate.dart';
import 'package:slipreel_engine/models/export_settings.dart';
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
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
      playbackSpeed: speed,
    );

NSliceFilterGraph _graphFor(List<ClipSlice> clips) =>
    buildExportFilterGraph(state: _stateWith(clips), audioStreams: const []);

void main() {
  // Web tier matches what the production pipeline picks for typical exports;
  // any non-default tier would only change the palette knobs, not the
  // per-slice + concat structure these tests are pinning.
  final palette = gifPaletteSettings(CompressionTier.web);

  group('GIF pass-1 filter_complex (palettegen)', () {
    test('1 slice → concat=n=1, ends in palettegen → [outpal]', () {
      final fc = buildGifPass1FilterComplex(
        videoGraph: _graphFor([_slice(cs: 0, ce: 10)]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('[v0]'));
      expect(fc, contains('concat=n=1:v=1:a=0[outv]'));
      expect(fc, contains('[outv]scale=640:480'));
      expect(fc, contains('palettegen'));
      expect(fc, contains('[outpal]'));
      // No audio in a GIF graph.
      expect(fc, isNot(contains('[outa]')));
      expect(fc, isNot(contains('amix')));
    });

    test('2 slices → two trim chains + concat=n=2', () {
      final fc = buildGifPass1FilterComplex(
        videoGraph: _graphFor([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12),
        ]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(
        RegExp(r'trim=start=0\.000000:end=5\.000000').hasMatch(fc),
        isTrue,
        reason: 'first slice trim node',
      );
      expect(
        RegExp(r'trim=start=5\.000000:end=12\.000000').hasMatch(fc),
        isTrue,
        reason: 'second slice trim node',
      );
      expect(fc, contains('[v0][v1]concat=n=2:v=1:a=0[outv]'));
    });

    test('3 slices → concat=n=3', () {
      final fc = buildGifPass1FilterComplex(
        videoGraph: _graphFor([
          _slice(cs: 0, ce: 3),
          _slice(cs: 3, ce: 7),
          _slice(cs: 7, ce: 12),
        ]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('[v0][v1][v2]concat=n=3:v=1:a=0[outv]'));
    });

    test('per-slice playbackSpeed drives setpts factor', () {
      final fc = buildGifPass1FilterComplex(
        videoGraph: _graphFor([
          _slice(cs: 0, ce: 5, speed: 2.0),
          _slice(cs: 5, ce: 12, speed: 0.5),
        ]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('setpts=(PTS-STARTPTS)/2.0'));
      expect(fc, contains('setpts=(PTS-STARTPTS)/0.5'));
    });

    test('trim bounds drive trim=, NOT cut bounds', () {
      final fc = buildGifPass1FilterComplex(
        videoGraph: _graphFor([_slice(cs: 0, ce: 10, ts: 2, te: 8)]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('trim=start=2.000000:end=8.000000'));
      expect(fc, isNot(contains('trim=start=0.000000:end=10.000000')));
    });

    test('palette knobs reach the palettegen filter', () {
      final fc = buildGifPass1FilterComplex(
        videoGraph: _graphFor([_slice(cs: 0, ce: 5)]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('max_colors=${palette.maxColors}'));
      expect(fc, contains('stats_mode=full'));
    });
  });

  group('GIF pass-2 filter_complex (paletteuse)', () {
    test('1 slice → concat=n=1, paletteuse → [gifout]', () {
      final fc = buildGifPass2FilterComplex(
        videoGraph: _graphFor([_slice(cs: 0, ce: 10)]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('concat=n=1:v=1:a=0[outv]'));
      expect(fc, contains('[outv]scale=640:480'));
      expect(fc, contains('[scaled]'));
      expect(fc, contains('[scaled][1:v]paletteuse'));
      expect(fc, contains('[gifout]'));
      expect(fc, isNot(contains('palettegen')));
    });

    test('2 slices → concat=n=2 in front of paletteuse', () {
      final fc = buildGifPass2FilterComplex(
        videoGraph: _graphFor([
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 12),
        ]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('[v0][v1]concat=n=2:v=1:a=0[outv]'));
      expect(fc, contains('[scaled][1:v]paletteuse'));
    });

    test('dither setting reaches paletteuse', () {
      final fc = buildGifPass2FilterComplex(
        videoGraph: _graphFor([_slice(cs: 0, ce: 5)]),
        outWidth: 640,
        outHeight: 480,
        paletteSettings: palette,
      );
      expect(fc, contains('dither=${palette.dither}'));
    });
  });
}
