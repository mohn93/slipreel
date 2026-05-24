import 'dart:ui' show Offset;

import 'package:flutter/widgets.dart' show Size;
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';

/// Deterministic, position-pure camera-focal trajectory for one zoom
/// region. Replays a fresh [ScenePassBuilder] (which drives the same
/// smoothed-cursor + critically-damped-spring focal pipeline the live
/// camera uses) from the region's start to its end at a fixed 16 ms
/// step, caches the per-step focal, and answers [focalAt] by
/// interpolation.
///
/// Why this exists: the scene-blur pan vector must measure how the
/// *spring camera* moved across the exposure window, not how the raw
/// cursor moved — otherwise the smear diverges from on-screen motion at
/// zoom enter/exit (the cursor-follow "crack"). Sampling raw cursor was
/// also why a previous fix snapped the focal to the cursor in one frame.
/// Replaying the real pipeline keeps the blur matched to the camera, and
/// because the replay is a pure function of its inputs the signal is
/// identical for pause / play / scrub / export at the same playhead.
class DeterministicFocalTrack {
  DeterministicFocalTrack._({
    required this.region,
    required this.cursorRecording,
    required this.cursorAnimationConfig,
    required this.cursorPostProcess,
    required this.videoSize,
    required this.fps,
    required List<Offset> samples,
    required int startMicros,
  })  : _samples = List.unmodifiable(samples),
        _startMicros = startMicros;

  /// Fixed sub-step in microseconds. Matches [ZoomFocalController]'s
  /// maximum sub-step (16 ms) so the replay integrates identically to a
  /// 60 fps live pass.
  static const int _stepMicros = 16000;

  final ZoomRegion region;
  final CursorRecording cursorRecording;
  final CursorAnimationConfig cursorAnimationConfig;
  final CursorPostProcess cursorPostProcess;
  final Size videoSize;
  final int fps;

  final List<Offset> _samples; // focal per fixed step from _startMicros
  final int _startMicros;

  /// Builds (and integrates) the trajectory for [region] by replaying a
  /// fresh [ScenePassBuilder] from [region.startTime] to [region.endTime]
  /// in [_stepMicros] increments. Call once per region; reuse the
  /// instance for every per-frame [focalAt] lookup.
  static DeterministicFocalTrack build({
    required ZoomRegion region,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig cursorAnimationConfig,
    required Size videoSize,
    required int fps,
    CursorPostProcess cursorPostProcess = CursorPostProcess.none,
  }) {
    final builder = ScenePassBuilder();
    final regions = <ZoomRegion>[region];
    final startUs = region.startTime.inMicroseconds;
    final endUs = region.endTime.inMicroseconds;
    final hasCursor = cursorRecording.count > 0;
    final samples = <Offset>[];

    for (var us = startUs; us <= endUs; us += _stepMicros) {
      final pass = builder.build(
        position: Duration(microseconds: us),
        zoomRegions: regions,
        cursorAnimationConfig: cursorAnimationConfig,
        cursorPostProcess: cursorPostProcess,
        cursorRecording: cursorRecording,
        videoSize: videoSize,
        fps: fps,
        hasCursorData: hasCursor,
      );
      final focal = pass.focalUpdate?.focal;
      // The loop only visits timestamps inside [startUs, endUs], where the
      // region's zoom is active, so focalUpdate is always non-null. A null
      // here means an invariant changed (e.g. the loop bounds or the
      // controller's active-window contract) — surface it loudly in debug.
      assert(
        focal != null,
        'DeterministicFocalTrack: focalUpdate null inside region bounds at '
        '${Duration(microseconds: us)}',
      );
      if (focal == null) break; // release-mode safety net
      samples.add(focal);
    }

    return DeterministicFocalTrack._(
      region: region,
      cursorRecording: cursorRecording,
      cursorAnimationConfig: cursorAnimationConfig,
      cursorPostProcess: cursorPostProcess,
      videoSize: videoSize,
      fps: fps,
      samples: samples,
      startMicros: startUs,
    );
  }

  /// Focal at [t], interpolated from the cached trajectory. Clamps to
  /// the covered range. Returns [region.rect.center] when the trajectory
  /// is empty (no active zoom was seen during replay).
  Offset focalAt(Duration t) {
    if (_samples.isEmpty) return region.rect.center;
    if (_samples.length == 1) return _samples.first;

    final rel = t.inMicroseconds - _startMicros;
    if (rel <= 0) return _samples.first;

    final lastIdx = _samples.length - 1;
    final maxRel = lastIdx * _stepMicros;
    if (rel >= maxRel) return _samples[lastIdx];

    final i = rel ~/ _stepMicros;
    final f = (rel - i * _stepMicros) / _stepMicros;
    return Offset.lerp(_samples[i], _samples[i + 1], f)!;
  }

  /// True when this track was built from inputs equal to the given set —
  /// used by callers to decide whether to rebuild after a widget update.
  /// [cursorRecording] is compared by identity (the shell swaps the whole
  /// object when the recording changes). Everything else is compared by
  /// value — [cursorAnimationConfig] implements value `==`, so a caller
  /// passing a freshly-constructed-but-equal config (e.g. an inline
  /// `CursorAnimationConfig.preset(...)`) does not thrash the cache.
  bool matches({
    required ZoomRegion region,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig cursorAnimationConfig,
    required CursorPostProcess cursorPostProcess,
    required Size videoSize,
    required int fps,
  }) {
    return identical(this.cursorRecording, cursorRecording) &&
        this.cursorAnimationConfig == cursorAnimationConfig &&
        this.region == region &&
        this.cursorPostProcess == cursorPostProcess &&
        this.videoSize == videoSize &&
        this.fps == fps;
  }
}
