import 'dart:ui' show Offset;

import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart' show Size;
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
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
    required this.cursorRecordingVersion,
    required this.cursorAnimationConfig,
    required this.cursorPostProcess,
    required this.cursorDelay,
    required this.screenRampCurve,
    required this.rampDurationScale,
    required this.tuning,
    required this.videoSize,
    required this.fps,
    required this.clips,
    required this.framing,
    required List<Offset> samples,
    required int startMicros,
  }) : _samples = List.unmodifiable(samples),
       _startMicros = startMicros;

  /// Fixed sub-step in microseconds. Matches [ZoomFocalController]'s
  /// maximum sub-step (16 ms) so the replay integrates identically to a
  /// 60 fps live pass.
  static const int _stepMicros = 16000;

  final ZoomRegion region;
  final CursorRecording cursorRecording;
  final int cursorRecordingVersion;
  final CursorAnimationConfig cursorAnimationConfig;
  final CursorPostProcess cursorPostProcess;

  /// Cursor sprite delay the live camera follows. The focal chases the
  /// spring-smoothed *sprite*, which is sampled at `position - cursorDelay`,
  /// so the replay must apply the same delay or the deterministic focal would
  /// diverge from the live one by `cursorDelay` of cursor motion (a visible
  /// jump at the play↔scrub boundary). Defaults to zero for callers without a
  /// delayed cursor; preview and export both pass the project value explicitly.
  final Duration cursorDelay;

  /// Screen ramp curve forwarded to the replayed [ScenePassBuilder] so the
  /// deterministic enter/exit focal ramps match the live camera's. Default
  /// [Curves.easeInOutQuad] keeps export (which omits it) unchanged.
  final Curve screenRampCurve;

  /// Multiplier on the zoom region's enter/exit ramp duration, forwarded to
  /// the replayed [ScenePassBuilder] so the deterministic focal ramps push
  /// at the same speed as the live camera. Part of the cache key in
  /// [matches] so flipping the feel invalidates a stale track.
  final double rampDurationScale;

  /// Motion constants used by both cursor and focal springs during replay.
  /// Compared by identity in [matches]: providers/stores retain one immutable
  /// instance until the user changes tuning, at which point the track must be
  /// rebuilt rather than silently continuing with defaults.
  final MotionTuning tuning;

  final Size videoSize;
  final int fps;

  /// Clip slices forwarded to the replayed [ScenePassBuilder] so the
  /// deterministic cursor — and therefore the focal that chases it — is
  /// resolved at the same playback speed the live/exported cursor uses.
  /// Without this the replay always runs at speed 1.0, so over a zoom
  /// region overlapping a sped-up slice the camera would track a different
  /// cursor path than the one drawn (the cursor-follow "crack"). Defaults
  /// to empty, which keeps existing callers/tests at speed 1.0.
  final List<ClipSlice> clips;

  /// Device-bezel framing forwarded to each replayed [ScenePassBuilder]
  /// step so clamps are resolved in canvas space. Null ⇒ identity framing
  /// ⇒ byte-identical to the legacy no-device-frame behavior.
  final ZoomFraming? framing;

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
    Duration cursorDelay = Duration.zero,
    Curve screenRampCurve = Curves.easeInOutQuad,
    double rampDurationScale = 1.0,
    MotionTuning tuning = MotionTuning.defaults,
    List<ClipSlice> clips = const <ClipSlice>[],
    ZoomFraming? framing,
  }) {
    final builder = ScenePassBuilder()..setTuning(tuning);
    final regions = <ZoomRegion>[region];
    final startUs = region.startTime.inMicroseconds;
    final endUs = region.endTime.inMicroseconds;
    final hasCursor = cursorRecording.count > 0;
    final samples = <Offset>[];

    for (var us = startUs; us < endUs; us += _stepMicros) {
      final pass = builder.build(
        position: Duration(microseconds: us),
        zoomRegions: regions,
        cursorAnimationConfig: cursorAnimationConfig,
        cursorDelay: cursorDelay,
        cursorPostProcess: cursorPostProcess,
        cursorRecording: cursorRecording,
        videoSize: videoSize,
        fps: fps,
        hasCursorData: hasCursor,
        screenRampCurve: screenRampCurve,
        rampDurationScale: rampDurationScale,
        clips: clips,
        framing: framing,
      );
      final focal = pass.focalUpdate?.focal;
      // The loop only visits timestamps inside [startUs, endUs), where the
      // region's zoom is active (ZoomRegion.isActive is a half-open interval),
      // so focalUpdate is always non-null. A null here means an invariant
      // changed (e.g. the loop bounds or the controller's active-window
      // contract) — surface it loudly in debug.
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
      cursorRecordingVersion: cursorRecording.version,
      cursorAnimationConfig: cursorAnimationConfig,
      cursorPostProcess: cursorPostProcess,
      cursorDelay: cursorDelay,
      screenRampCurve: screenRampCurve,
      rampDurationScale: rampDurationScale,
      tuning: tuning,
      videoSize: videoSize,
      fps: fps,
      clips: clips,
      framing: framing,
      samples: samples,
      startMicros: startUs,
    );
  }

  /// Focal at [t], interpolated from the cached trajectory. Clamps to
  /// the covered range. Returns the region's base focal when the trajectory
  /// is empty (no active zoom was seen during replay).
  Offset focalAt(Duration t) {
    if (_samples.isEmpty) {
      return region.followCursor
          ? videoSize.center(Offset.zero)
          : region.rect.center;
    }
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
    Duration cursorDelay = Duration.zero,
    Curve screenRampCurve = Curves.easeInOutQuad,
    double rampDurationScale = 1.0,
    MotionTuning tuning = MotionTuning.defaults,
    List<ClipSlice> clips = const <ClipSlice>[],
    ZoomFraming? framing,
  }) {
    bool sameFraming(ZoomFraming? a, ZoomFraming? b) {
      if (a == null || b == null) return (a == null) == (b == null);
      return a.isIdentity == b.isIdentity &&
          a.videoSize == b.videoSize &&
          a.videoRect == b.videoRect &&
          a.canvasSize == b.canvasSize;
    }

    return identical(this.cursorRecording, cursorRecording) &&
        cursorRecordingVersion == cursorRecording.version &&
        this.cursorAnimationConfig == cursorAnimationConfig &&
        this.region == region &&
        this.cursorPostProcess == cursorPostProcess &&
        this.cursorDelay == cursorDelay &&
        this.screenRampCurve == screenRampCurve &&
        this.rampDurationScale == rampDurationScale &&
        identical(this.tuning, tuning) &&
        this.videoSize == videoSize &&
        this.fps == fps &&
        listEquals(this.clips, clips) &&
        sameFraming(this.framing, framing);
  }
}
